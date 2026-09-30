// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "types/screencopy_sdr.h"
#include "screencopy-sdr-reference.h"

static const uint32_t formats[] = {
	DRM_FORMAT_XRGB2101010, DRM_FORMAT_ARGB2101010,
	DRM_FORMAT_XBGR2101010, DRM_FORMAT_ABGR2101010,
};

static void pack(uint8_t *dst, uint32_t format, unsigned r, unsigned g, unsigned b) {
	bool bgr = format == DRM_FORMAT_XBGR2101010 || format == DRM_FORMAT_ABGR2101010;
	uint32_t pixel = bgr ? r | g << 10 | b << 20 : b | g << 10 | r << 20;
	// Alpha deliberately zero: screencopy's XRGB result must be opaque.
	for (size_t i = 0; i < 4; i++) {
		dst[i] = pixel >> (i * 8);
	}
}

static void expect_pixel(const uint8_t *pixel, int r, int g, int b, int tolerance) {
	assert(abs(pixel[2] - r) <= tolerance);
	assert(abs(pixel[1] - g) <= tolerance);
	assert(abs(pixel[0] - b) <= tolerance);
	assert(pixel[3] == 255);
}

// Encode known scene colors to HDR independently of the capture conversion.
static unsigned pq_code(double nits) {
	double p = pow(nits / 10000.0, 2610.0 / 16384.0);
	return (unsigned)lround(pow((3424.0 / 4096.0 + (2413.0 / 128.0) * p) /
		(1.0 + (2392.0 / 128.0) * p), 2523.0 / 32.0) * 1023.0);
}

static uint32_t random_bits(uint32_t *state) {
	*state ^= *state << 13;
	*state ^= *state >> 17;
	*state ^= *state << 5;
	return *state;
}

static void *get_gamma(void *unused) {
	(void)unused;
	const struct screencopy_sdr_gamma *gamma = screencopy_sdr_gamma_get();
	assert(gamma->threshold[1] > 0 && gamma->threshold[255] < 1);
	return (void *)gamma;
}

static void check_encoder(bool exhaustive) {
	// Exercise concurrent first use, before any conversion initializes the table.
	pthread_t threads[8];
	for (size_t i = 0; i < 8; i++) assert(pthread_create(&threads[i], NULL, get_gamma, NULL) == 0);
	const struct screencopy_sdr_gamma *gamma = screencopy_sdr_gamma_get();
	for (size_t i = 0; i < 8; i++) {
		void *result;
		assert(pthread_join(threads[i], &result) == 0 && result == gamma);
	}
	for (unsigned code = 1; code < 256; code++) {
		float threshold = gamma->threshold[code];
		assert(threshold > gamma->threshold[code - 1]);
		assert(reference_encode(threshold) == code);
		assert(reference_encode(nextafterf(threshold, 0)) == code - 1);
		uint32_t bits;
		memcpy(&bits, &threshold, sizeof(bits));
		// A neighborhood, not just the bisection's endpoints, checks local
		// monotonicity of the platform libm at the quantization boundaries.
		for (int offset = -1024; offset <= 1024; offset++) {
			uint32_t sample_bits = bits + offset;
			float value;
			memcpy(&value, &sample_bits, sizeof(value));
			assert(screencopy_sdr_encode(gamma, value) == reference_encode(value));
		}
	}
	const float special[] = {-INFINITY, -1, -0.0f, 0, 1, 2, INFINITY, NAN};
	for (size_t i = 0; i < sizeof(special) / sizeof(special[0]); i++)
		assert(screencopy_sdr_encode(gamma, special[i]) == reference_encode(special[i]));
	for (unsigned bucket = 0; bucket < 4096; bucket++) {
		float lower = (float)bucket / 4096.0f;
		assert(gamma->coarse[bucket] == reference_encode(lower));
		assert(screencopy_sdr_encode(gamma, lower) == reference_encode(lower));
		float upper = nextafterf((float)(bucket + 1) / 4096.0f, 0);
		assert(screencopy_sdr_encode(gamma, upper) == reference_encode(upper));
	}
	uint32_t state = 0x243f6a88;
	uint8_t previous = 0;
	for (unsigned i = 0; i <= 1000000; i++) {
		float value = (float)i / 1000000;
		uint8_t encoded = screencopy_sdr_encode(gamma, value);
		assert(encoded == reference_encode(value) && encoded >= previous);
		previous = encoded;
		// Bit-distributed samples include subnormals and the near-black region.
		uint32_t bits = random_bits(&state) % 0x3f800001;
		memcpy(&value, &bits, sizeof(value));
		assert(screencopy_sdr_encode(gamma, value) == reference_encode(value));
	}
	if (exhaustive) {
		for (uint32_t bits = 0; bits <= 0x3f800000; bits++) {
			float value;
			memcpy(&value, &bits, sizeof(value));
			assert(screencopy_sdr_encode(gamma, value) == reference_encode(value));
		}
		puts("PASS: every binary32 input in [0, 1] agrees with the original encoder");
	}
	puts("PASS: shared gamma initialization, boundaries, clipping, dense/random encoder equivalence");
}

static void check_pixels(void) {
	enum { width = 1027, height = 9, src_stride = width * 4 + 13, dst_stride = width * 4 + 19 };
	uint8_t src[height * src_stride + 1], actual[height * dst_stride + 1], expected[sizeof(actual)];
	uint32_t state = 0x85a308d3;
	const double whites[] = {0, 80, 200, 400, 1000};
	const enum wlr_color_named_primaries primaries[] = {
		WLR_COLOR_NAMED_PRIMARIES_SRGB, WLR_COLOR_NAMED_PRIMARIES_BT2020,
	};
	for (size_t f = 0; f < sizeof(formats) / sizeof(formats[0]); f++) {
		for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) {
			unsigned r = y == 0 ? (unsigned)x % 1024 : random_bits(&state) & 1023;
			unsigned g = y == 0 ? r : random_bits(&state) & 1023;
			unsigned b = y == 0 ? r : random_bits(&state) & 1023;
			pack(src + 1 + y * src_stride + x * 4, formats[f], r, g, b);
		}
		// Reuse the same object across transfer, gamut and white-level changes.
		struct screencopy_sdr_conversion conv;
		for (size_t p = 0; p < 2; p++) for (size_t w = 0; w < 5; w++) for (int pq = 0; pq < 2; pq++) {
			struct wlr_output_image_description desc = {
				.primaries = primaries[p],
				.transfer_function = pq ? WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ : WLR_COLOR_TRANSFER_FUNCTION_GAMMA22,
				.sdr_white_level = whites[w],
			};
			screencopy_sdr_conversion_init(&conv, &desc);
			memset(actual, 0xA5, sizeof(actual));
			memset(expected, 0xA5, sizeof(expected));
			screencopy_sdr_convert(&conv, formats[f], src + 1, src_stride,
				actual + 1, dst_stride, width, height);
			reference_convert(&conv, formats[f], src + 1, src_stride,
				expected + 1, dst_stride, width, height);
			assert(memcmp(actual, expected, sizeof(actual)) == 0);
		}
	}
	puts("PASS: byte-exact HDR/SDR pixels, gamuts, white changes, odd dimensions, unaligned rows and padding");
}

int main(int argc, char **argv) {
	assert(argc == 1 || (argc == 2 && strcmp(argv[1], "--exhaustive") == 0));
	check_encoder(argc == 2);
	check_pixels();
	assert(screencopy_shm_format(DRM_FORMAT_INVALID) == DRM_FORMAT_INVALID);
	assert(screencopy_shm_format(DRM_FORMAT_XRGB8888) == DRM_FORMAT_XRGB8888);
	assert(screencopy_shm_format(DRM_FORMAT_ABGR8888) == DRM_FORMAT_ABGR8888);
	for (size_t f = 0; f < sizeof(formats) / sizeof(formats[0]); f++) {
		uint32_t format = formats[f];
		assert(screencopy_shm_format(format) == DRM_FORMAT_XRGB8888);
		struct screencopy_sdr_conversion conv;
		screencopy_sdr_conversion_init(&conv, NULL);
		uint8_t src[24], dst[32];
		memset(src, 0xA5, sizeof(src));
		memset(dst, 0xA5, sizeof(dst));
		pack(src, format, 1023, 0, 0);
		pack(src + 4, format, 0, 1023, 0);
		pack(src + 12, format, 0, 0, 1023);
		pack(src + 16, format, 512, 512, 512);
		screencopy_sdr_convert(&conv, format, src, 12, dst, 16, 2, 2);
		expect_pixel(dst, 255, 0, 0, 0);
		expect_pixel(dst + 4, 0, 255, 0, 0);
		expect_pixel(dst + 16, 0, 0, 255, 0);
		expect_pixel(dst + 20, 128, 128, 128, 0);
		for (size_t i = 8; i < 16; i++) {
			assert(dst[i] == 0xA5 && dst[i + 16] == 0xA5);
		}

		const double whites[] = {0, 80, 200, 400, 1000};
		for (size_t w = 0; w < sizeof(whites) / sizeof(whites[0]); w++) {
			struct wlr_output_image_description desc = {
				.primaries = WLR_COLOR_NAMED_PRIMARIES_BT2020,
				.transfer_function = WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ,
				.sdr_white_level = whites[w],
			};
			screencopy_sdr_conversion_init(&conv, &desc);
			double white = whites[w] > 0 ? whites[w] : 203;
			pack(src, format, 0, 0, 0);
			screencopy_sdr_convert(&conv, format, src, 4, dst, 4, 1, 1);
			expect_pixel(dst, 0, 0, 0, 0);
			unsigned code = pq_code(white);
			pack(src, format, code, code, code);
			screencopy_sdr_convert(&conv, format, src, 4, dst, 4, 1, 1);
			expect_pixel(dst, 255, 255, 255, 1);
			code = pq_code(white * pow(0.5, 2.2));
			pack(src, format, code, code, code);
			screencopy_sdr_convert(&conv, format, src, 4, dst, 4, 1, 1);
			expect_pixel(dst, 128, 128, 128, 1);

			// Linear sRGB -> BT.2020 matrix: an asymmetric colored patch
			// catches missing gamut conversion, transposition, and R/B swaps.
			double r = pow(192.0 / 255.0, 2.2);
			double g = pow(64.0 / 255.0, 2.2);
			double b = pow(128.0 / 255.0, 2.2);
			pack(src, format,
				pq_code(white * (0.627404 * r + 0.329283 * g + 0.043313 * b)),
				pq_code(white * (0.069097 * r + 0.919540 * g + 0.011362 * b)),
				pq_code(white * (0.016391 * r + 0.088013 * g + 0.895595 * b)));
			screencopy_sdr_convert(&conv, format, src, 4, dst, 4, 1, 1);
			expect_pixel(dst, 192, 64, 128, 2);

			pack(src, format, 1023, 1023, 1023);
			screencopy_sdr_convert(&conv, format, src, 4, dst, 4, 1, 1);
			expect_pixel(dst, 255, 255, 255, 0);
			pack(src, format, 1023, 0, 0);
			screencopy_sdr_convert(&conv, format, src, 4, dst, 4, 1, 1);
			expect_pixel(dst, 255, 0, 0, 0);
		}
	}
	puts("PASS: 10-bit screencopy formats, packing, stride, HDR colors and SDR white levels");
	return 0;
}

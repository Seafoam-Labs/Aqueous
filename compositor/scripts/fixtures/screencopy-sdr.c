// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "types/screencopy_sdr.h"

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

int main(void) {
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

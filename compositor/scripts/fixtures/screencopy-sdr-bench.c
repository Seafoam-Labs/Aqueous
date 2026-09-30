// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "types/screencopy_sdr.h"
#include "screencopy-sdr-reference.h"

static double now_ms(void) {
	struct timespec ts;
	assert(clock_gettime(CLOCK_MONOTONIC, &ts) == 0);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

static int compare_double(const void *a, const void *b) {
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

int main(int argc, char **argv) {
	assert(argc == 2 && (!strcmp(argv[1], "1080p") || !strcmp(argv[1], "4k")));
	int width = !strcmp(argv[1], "4k") ? 3840 : 1920;
	int height = !strcmp(argv[1], "4k") ? 2160 : 1080;
	size_t stride = (size_t)width * 4, size = stride * height;
	uint32_t *src = malloc(size);
	uint8_t *actual = malloc(size), *expected = malloc(size);
	assert(src && actual && expected);
	struct wlr_output_image_description desc = {
		.primaries = WLR_COLOR_NAMED_PRIMARIES_BT2020,
		.transfer_function = WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ,
		.sdr_white_level = 200,
	};
	double start = now_ms();
	const struct screencopy_sdr_gamma *gamma = screencopy_sdr_gamma_get();
	printf("BENCH gamma first initialization %.3f ms, table %zu bytes\n", now_ms() - start, sizeof(*gamma));
	struct screencopy_sdr_conversion conv;
	start = now_ms();
	for (unsigned i = 0; i < 100; i++) screencopy_sdr_conversion_init(&conv, &desc);
	printf("BENCH per-frame PQ/matrix initialization mean %.3f ms (100 samples)\n", (now_ms() - start) / 100);
	const char *patterns[] = {"gradient", "near-black", "saturated", "random"};
	for (unsigned pattern = 0; pattern < 4; pattern++) {
		uint32_t state = 0x243f6a88;
		for (size_t i = 0; i < (size_t)width * height; i++) {
			unsigned r, g, b;
			if (pattern < 2) {
				r = g = b = (i % (size_t)width) * (pattern ? 128 : 1024) / width;
			} else if (pattern == 2) {
				r = i % 3 == 0 ? 1023 : 0;
				g = i % 3 == 1 ? 1023 : 0;
				b = i % 3 == 2 ? 1023 : 0;
			} else {
				state ^= state << 13; state ^= state >> 17; state ^= state << 5;
				r = state & 1023; g = (state >> 10) & 1023; b = (state >> 20) & 1023;
			}
			src[i] = r << 20 | g << 10 | b;
		}
		enum { warmup = 3, samples = 20 };
		double reference[samples], lookup[samples];
		for (int i = -warmup; i < samples; i++) {
			// Alternate order to reduce cache/clock bias. Allocation, PQ setup,
			// readback, data generation and verification are outside the timers.
			for (unsigned pass = 0; pass < 2; pass++) {
				bool optimized = ((i + warmup + (int)pass) % 2) == 0;
				start = now_ms();
				if (optimized) {
					screencopy_sdr_convert(&conv, DRM_FORMAT_XRGB2101010,
						(const uint8_t *)src, stride, actual, stride, width, height);
				} else {
					reference_convert(&conv, DRM_FORMAT_XRGB2101010,
						(const uint8_t *)src, stride, expected, stride, width, height);
				}
				double elapsed = now_ms() - start;
				if (i >= 0) (optimized ? lookup : reference)[i] = elapsed;
			}
			assert(memcmp(actual, expected, size) == 0);
		}
		qsort(reference, samples, sizeof(double), compare_double);
		qsort(lookup, samples, sizeof(double), compare_double);
		double old_median = (reference[9] + reference[10]) / 2;
		double new_median = (lookup[9] + lookup[10]) / 2;
		printf("BENCH %dx%d %-10s reference median %.3f ms p95 %.3f ms; lookup median %.3f ms p95 %.3f ms; %.2fx (%d samples)\n",
			width, height, patterns[pattern], old_median, reference[18], new_median, lookup[18], old_median / new_median, samples);
	}
	free(expected); free(actual); free(src);
	return 0;
}

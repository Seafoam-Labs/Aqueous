// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <wlr/types/wlr_color_management_v1.h>

static void expect_luminances(const char *name,
		struct wlr_color_luminances luminances, uint32_t reference_headroom_max_lum,
		uint32_t expected_min, uint32_t expected_max, uint32_t expected_reference) {
	uint32_t min_lum = UINT32_MAX;
	uint32_t max_lum = UINT32_MAX;
	uint32_t reference_lum = UINT32_MAX;
	wlr_color_manager_v1_encode_luminances(&luminances, reference_headroom_max_lum,
		&min_lum, &max_lum, &reference_lum);
	if (min_lum != expected_min || max_lum != expected_max ||
			reference_lum != expected_reference) {
		fprintf(stderr,
			"FAIL: %s encoded as (%u, %u, %u), expected (%u, %u, %u)\n",
			name, min_lum, max_lum, reference_lum,
			expected_min, expected_max, expected_reference);
		exit(EXIT_FAILURE);
	}
	if (reference_headroom_max_lum > 0 &&
			reference_lum >= reference_headroom_max_lum) {
		fprintf(stderr,
			"FAIL: %s does not satisfy Proton HDR detection (%u !< %u)\n",
			name, reference_lum, reference_headroom_max_lum);
		exit(EXIT_FAILURE);
	}
}

int main(void) {
	_Static_assert(WLR_COLOR_MANAGER_V1_WINDOWS_HDR_SCRGB == 1 << 0,
		"Windows scRGB feature bit changed");
	_Static_assert(WLR_COLOR_MANAGER_V1_WINDOWS_HDR_BT2100 == 1 << 1,
		"Windows BT.2100 feature bit changed");

	expect_luminances("PQ defaults",
		(struct wlr_color_luminances){ .min = 0.005f, .max = 10000, .reference = 203 },
		1000, 50, 10000, 203);
	expect_luminances("PQ reference equals 400-nit target",
		(struct wlr_color_luminances){ .min = 0.005f, .max = 10000, .reference = 400 },
		400, 50, 10000, 399);
	expect_luminances("PQ reference equals 1000-nit target",
		(struct wlr_color_luminances){ .min = 0.005f, .max = 10000, .reference = 1000 },
		1000, 50, 10000, 999);
	expect_luminances("PQ reference exceeds 100-nit target",
		(struct wlr_color_luminances){ .min = 0.005f, .max = 10000, .reference = 200 },
		100, 50, 10000, 99);
	expect_luminances("PQ rounded target boundary",
		(struct wlr_color_luminances){ .min = 0, .max = 10000, .reference = 399.6f },
		400, 0, 10000, 399);
	expect_luminances("SDR permits equal max and reference",
		(struct wlr_color_luminances){ .min = 0.2f, .max = 80, .reference = 80 },
		0, 2000, 80, 80);
	expect_luminances("no target headroom preserves equality",
		(struct wlr_color_luminances){ .min = 0, .max = 10000, .reference = 9999.6f },
		0, 0, 10000, 10000);
	expect_luminances("zero maximum cannot underflow",
		(struct wlr_color_luminances){ .min = 0, .max = 0, .reference = 1 },
		0, 0, 0, 1);
	expect_luminances("one-nit target cannot underflow",
		(struct wlr_color_luminances){ .min = 0, .max = 10000, .reference = 1 },
		1, 0, 10000, 0);
	expect_luminances("invalid values are clamped",
		(struct wlr_color_luminances){ .min = -1, .max = INFINITY, .reference = NAN },
		1000, 0, 0, 0);

	puts("PASS: color-management luminance encoding and Proton HDR headroom");
	return EXIT_SUCCESS;
}

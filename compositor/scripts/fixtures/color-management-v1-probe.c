// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <wayland-client.h>
#include "color-management-v1-client-protocol.h"

struct description_result {
	bool ready;
	bool failed;
	bool ready_legacy;
	bool ready2;
	uint64_t identity;
};

struct output_information {
	bool done;
	bool saw_primaries;
	bool saw_primaries_named;
	bool saw_tf_named;
	bool saw_luminances;
	bool saw_target_primaries;
	bool saw_target_luminance;
	bool saw_max_cll;
	bool saw_max_fall;
	uint32_t primaries_named;
	uint32_t tf_named;
	uint32_t min_lum;
	uint32_t max_lum;
	uint32_t reference_lum;
	uint32_t target_min_lum;
	uint32_t target_max_lum;
};

struct probe {
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_compositor *compositor;
	struct wl_output *output;
	struct wp_color_manager_v1 *manager;
	uint32_t manager_global_name;
	uint32_t manager_global_version;
	bool manager_done;
	bool perceptual;
	bool windows_scrgb;
	bool windows_bt2100;
	bool ext_linear;
	bool pq;
	bool srgb;
	bool bt2020;
};

static void fail(const char *message) {
	fprintf(stderr, "FAIL: %s\n", message);
	exit(EXIT_FAILURE);
}

static void require_condition(bool condition, const char *message) {
	if (!condition) {
		fail(message);
	}
}

static void checked_roundtrip(struct probe *probe, const char *stage) {
	if (wl_display_roundtrip(probe->display) < 0) {
		fprintf(stderr, "FAIL: Wayland roundtrip failed during %s\n", stage);
		exit(EXIT_FAILURE);
	}
}

static void manager_supported_intent(void *data,
		struct wp_color_manager_v1 *manager, uint32_t intent) {
	(void)manager;
	struct probe *probe = data;
	if (intent == WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL) {
		probe->perceptual = true;
	}
}

static void manager_supported_feature(void *data,
		struct wp_color_manager_v1 *manager, uint32_t feature) {
	(void)manager;
	struct probe *probe = data;
	if (feature == WP_COLOR_MANAGER_V1_FEATURE_WINDOWS_SCRGB) {
		probe->windows_scrgb = true;
	} else if (feature == WP_COLOR_MANAGER_V1_FEATURE_WINDOWS_BT2100) {
		probe->windows_bt2100 = true;
	}
}

static void manager_supported_tf(void *data,
		struct wp_color_manager_v1 *manager, uint32_t transfer_function) {
	(void)manager;
	struct probe *probe = data;
	if (transfer_function == WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_EXT_LINEAR) {
		probe->ext_linear = true;
	} else if (transfer_function == WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ) {
		probe->pq = true;
	}
}

static void manager_supported_primaries(void *data,
		struct wp_color_manager_v1 *manager, uint32_t primaries) {
	(void)manager;
	struct probe *probe = data;
	if (primaries == WP_COLOR_MANAGER_V1_PRIMARIES_SRGB) {
		probe->srgb = true;
	} else if (primaries == WP_COLOR_MANAGER_V1_PRIMARIES_BT2020) {
		probe->bt2020 = true;
	}
}

static void manager_done(void *data, struct wp_color_manager_v1 *manager) {
	(void)manager;
	struct probe *probe = data;
	probe->manager_done = true;
}

static const struct wp_color_manager_v1_listener manager_listener = {
	.supported_intent = manager_supported_intent,
	.supported_feature = manager_supported_feature,
	.supported_tf_named = manager_supported_tf,
	.supported_primaries_named = manager_supported_primaries,
	.done = manager_done,
};

static void registry_global(void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	struct probe *probe = data;
	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		uint32_t bind_version = version < 4 ? version : 4;
		probe->compositor = wl_registry_bind(registry, name,
			&wl_compositor_interface, bind_version);
	} else if (strcmp(interface, wl_output_interface.name) == 0 && probe->output == NULL) {
		uint32_t bind_version = version < 4 ? version : 4;
		probe->output = wl_registry_bind(registry, name,
			&wl_output_interface, bind_version);
	} else if (strcmp(interface, wp_color_manager_v1_interface.name) == 0) {
		probe->manager_global_name = name;
		probe->manager_global_version = version;
		uint32_t bind_version = version < 3 ? version : 3;
		probe->manager = wl_registry_bind(registry, name,
			&wp_color_manager_v1_interface, bind_version);
		wp_color_manager_v1_add_listener(probe->manager, &manager_listener, probe);
	}
}

static void registry_global_remove(void *data, struct wl_registry *registry,
		uint32_t name) {
	(void)data;
	(void)registry;
	(void)name;
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

static void description_failed(void *data,
		struct wp_image_description_v1 *description, uint32_t cause,
		const char *message) {
	(void)description;
	struct description_result *result = data;
	result->failed = true;
	fprintf(stderr, "image description failed (cause %u): %s\n", cause, message);
}

static void description_ready(void *data,
		struct wp_image_description_v1 *description, uint32_t identity) {
	(void)description;
	struct description_result *result = data;
	result->ready = true;
	result->ready_legacy = true;
	result->identity = identity;
}

static void description_ready2(void *data,
		struct wp_image_description_v1 *description,
		uint32_t identity_hi, uint32_t identity_lo) {
	(void)description;
	struct description_result *result = data;
	result->ready = true;
	result->ready2 = true;
	result->identity = ((uint64_t)identity_hi << 32) | identity_lo;
}

static const struct wp_image_description_v1_listener description_listener = {
	.failed = description_failed,
	.ready = description_ready,
	.ready2 = description_ready2,
};

static void information_done(void *data,
		struct wp_image_description_info_v1 *information) {
	(void)information;
	struct output_information *result = data;
	result->done = true;
}

static void information_icc_file(void *data,
		struct wp_image_description_info_v1 *information,
		int32_t fd, uint32_t size) {
	(void)data;
	(void)information;
	(void)size;
	close(fd);
}

static void information_primaries(void *data,
		struct wp_image_description_info_v1 *information,
		int32_t r_x, int32_t r_y, int32_t g_x, int32_t g_y,
		int32_t b_x, int32_t b_y, int32_t w_x, int32_t w_y) {
	(void)information;
	(void)r_x;
	(void)r_y;
	(void)g_x;
	(void)g_y;
	(void)b_x;
	(void)b_y;
	(void)w_x;
	(void)w_y;
	struct output_information *result = data;
	result->saw_primaries = true;
}

static void information_primaries_named(void *data,
		struct wp_image_description_info_v1 *information, uint32_t primaries) {
	(void)information;
	struct output_information *result = data;
	result->saw_primaries_named = true;
	result->primaries_named = primaries;
}

static void information_tf_power(void *data,
		struct wp_image_description_info_v1 *information, uint32_t exponent) {
	(void)data;
	(void)information;
	(void)exponent;
}

static void information_tf_named(void *data,
		struct wp_image_description_info_v1 *information, uint32_t transfer_function) {
	(void)information;
	struct output_information *result = data;
	result->saw_tf_named = true;
	result->tf_named = transfer_function;
}

static void information_luminances(void *data,
		struct wp_image_description_info_v1 *information,
		uint32_t min_lum, uint32_t max_lum, uint32_t reference_lum) {
	(void)information;
	struct output_information *result = data;
	result->saw_luminances = true;
	result->min_lum = min_lum;
	result->max_lum = max_lum;
	result->reference_lum = reference_lum;
}

static void information_target_primaries(void *data,
		struct wp_image_description_info_v1 *information,
		int32_t r_x, int32_t r_y, int32_t g_x, int32_t g_y,
		int32_t b_x, int32_t b_y, int32_t w_x, int32_t w_y) {
	(void)information;
	(void)r_x;
	(void)r_y;
	(void)g_x;
	(void)g_y;
	(void)b_x;
	(void)b_y;
	(void)w_x;
	(void)w_y;
	struct output_information *result = data;
	result->saw_target_primaries = true;
}

static void information_target_luminance(void *data,
		struct wp_image_description_info_v1 *information,
		uint32_t min_lum, uint32_t max_lum) {
	(void)information;
	struct output_information *result = data;
	result->saw_target_luminance = true;
	result->target_min_lum = min_lum;
	result->target_max_lum = max_lum;
}

static void information_target_max_cll(void *data,
		struct wp_image_description_info_v1 *information, uint32_t max_cll) {
	(void)information;
	(void)max_cll;
	struct output_information *result = data;
	result->saw_max_cll = true;
}

static void information_target_max_fall(void *data,
		struct wp_image_description_info_v1 *information, uint32_t max_fall) {
	(void)information;
	(void)max_fall;
	struct output_information *result = data;
	result->saw_max_fall = true;
}

static const struct wp_image_description_info_v1_listener information_listener = {
	.done = information_done,
	.icc_file = information_icc_file,
	.primaries = information_primaries,
	.primaries_named = information_primaries_named,
	.tf_power = information_tf_power,
	.tf_named = information_tf_named,
	.luminances = information_luminances,
	.target_primaries = information_target_primaries,
	.target_luminance = information_target_luminance,
	.target_max_cll = information_target_max_cll,
	.target_max_fall = information_target_max_fall,
};

int main(void) {
	struct probe probe = {0};
	probe.display = wl_display_connect(NULL);
	require_condition(probe.display != NULL, "could not connect to Wayland display");
	probe.registry = wl_display_get_registry(probe.display);
	wl_registry_add_listener(probe.registry, &registry_listener, &probe);
	checked_roundtrip(&probe, "global discovery");
	checked_roundtrip(&probe, "color-manager capabilities");

	require_condition(probe.compositor != NULL, "wl_compositor was not advertised");
	require_condition(probe.output != NULL, "wl_output was not advertised");
	require_condition(probe.manager != NULL, "wp_color_manager_v1 was not advertised");
	require_condition(probe.manager_global_version >= 3,
		"wp_color_manager_v1 global is older than version 3");
	require_condition(probe.manager_done, "color-manager capability list was incomplete");
	require_condition(probe.perceptual, "perceptual rendering intent is missing");
	require_condition(probe.windows_scrgb, "Windows-scRGB feature is missing");
	require_condition(probe.windows_bt2100, "Windows-BT.2100 feature is missing");
	require_condition(probe.ext_linear && probe.srgb,
		"Windows-scRGB was advertised without its renderer encoding");
	require_condition(probe.pq && probe.bt2020,
		"Windows-BT.2100 was advertised without its renderer encoding");

	/* Proton-EM binds wp_color_manager_v1 at version 1 and determines HDR
	 * support from the output description's target/reference luminance
	 * headroom. Exercise that exact object-version and metadata path. */
	struct probe version1 = { .display = probe.display };
	version1.manager = wl_registry_bind(probe.registry, probe.manager_global_name,
		&wp_color_manager_v1_interface, 1);
	require_condition(version1.manager != NULL,
		"version 1 color-manager binding failed");
	require_condition(wp_color_manager_v1_get_version(version1.manager) == 1,
		"Proton-EM color-manager binding did not negotiate version 1");
	wp_color_manager_v1_add_listener(version1.manager, &manager_listener, &version1);
	checked_roundtrip(&probe, "version 1 Proton-EM capabilities");
	require_condition(version1.manager_done,
		"version 1 color-manager capability list was incomplete");
	require_condition(version1.perceptual,
		"version 1 client lost the perceptual rendering intent");
	require_condition(version1.windows_scrgb,
		"version 1 client lost Windows-scRGB compatibility");
	require_condition(!version1.windows_bt2100,
		"version 1 client received a version 3-only feature");
	require_condition(version1.ext_linear && version1.srgb,
		"version 1 Windows-scRGB encoding capabilities were incomplete");

	struct description_result version1_scrgb_result = {0};
	struct wp_image_description_v1 *version1_scrgb =
		wp_color_manager_v1_create_windows_scrgb(version1.manager);
	require_condition(wp_image_description_v1_get_version(version1_scrgb) == 1,
		"version 1 Windows-scRGB description negotiated the wrong version");
	wp_image_description_v1_add_listener(version1_scrgb,
		&description_listener, &version1_scrgb_result);
	checked_roundtrip(&probe, "version 1 Windows-scRGB description");
	require_condition(version1_scrgb_result.ready && !version1_scrgb_result.failed,
		"version 1 Windows-scRGB image description was not ready");
	require_condition(version1_scrgb_result.ready_legacy &&
		!version1_scrgb_result.ready2,
		"version 1 Windows-scRGB description did not use the legacy ready event");

	struct wp_color_management_output_v1 *version1_color_output =
		wp_color_manager_v1_get_output(version1.manager, probe.output);
	require_condition(wp_color_management_output_v1_get_version(version1_color_output) == 1,
		"version 1 color-management output negotiated the wrong version");
	struct description_result version1_output_description_result = {0};
	struct wp_image_description_v1 *version1_output_description =
		wp_color_management_output_v1_get_image_description(version1_color_output);
	require_condition(wp_image_description_v1_get_version(version1_output_description) == 1,
		"version 1 output description negotiated the wrong version");
	wp_image_description_v1_add_listener(version1_output_description,
		&description_listener, &version1_output_description_result);
	checked_roundtrip(&probe, "version 1 Proton-EM output description");
	require_condition(version1_output_description_result.ready &&
		!version1_output_description_result.failed,
		"version 1 output image description was not ready");
	require_condition(version1_output_description_result.ready_legacy &&
		!version1_output_description_result.ready2,
		"version 1 output description did not use the legacy ready event");
	require_condition(version1_output_description_result.identity != 0,
		"version 1 output image description identity was zero");

	struct output_information version1_output_info = {0};
	struct wp_image_description_info_v1 *version1_information =
		wp_image_description_v1_get_information(version1_output_description);
	require_condition(wp_image_description_info_v1_get_version(version1_information) == 1,
		"version 1 output information negotiated the wrong version");
	wp_image_description_info_v1_add_listener(version1_information,
		&information_listener, &version1_output_info);
	checked_roundtrip(&probe, "version 1 Proton-EM output information");
	require_condition(version1_output_info.done,
		"version 1 output image-description information was incomplete");
	require_condition(version1_output_info.saw_luminances &&
		version1_output_info.saw_target_luminance,
		"version 1 output omitted Proton-EM luminance metadata");
	require_condition(version1_output_info.reference_lum == 80 &&
		version1_output_info.target_max_lum == 80,
		"version 1 headless SDR output luminance metadata changed");
	bool version1_proton_hdr = version1_output_info.target_max_lum >
		version1_output_info.reference_lum;
	require_condition(!version1_proton_hdr,
		"version 1 Proton-EM predicate falsely detected HDR on an SDR output");

	/* Version 2 is the previous Aqueous/tooling contract. It must retain the
	 * v1 Windows-scRGB request without leaking the v3-only BT.2100 feature. */
	struct probe version2 = { .display = probe.display };
	version2.manager = wl_registry_bind(probe.registry, probe.manager_global_name,
		&wp_color_manager_v1_interface, 2);
	wp_color_manager_v1_add_listener(version2.manager, &manager_listener, &version2);
	checked_roundtrip(&probe, "version 2 compatibility capabilities");
	require_condition(version2.manager_done,
		"version 2 color-manager capability list was incomplete");
	require_condition(version2.windows_scrgb,
		"version 2 client lost Windows-scRGB compatibility");
	require_condition(!version2.windows_bt2100,
		"version 2 client received a version 3-only feature");
	struct description_result version2_scrgb_result = {0};
	struct wp_image_description_v1 *version2_scrgb =
		wp_color_manager_v1_create_windows_scrgb(version2.manager);
	wp_image_description_v1_add_listener(version2_scrgb,
		&description_listener, &version2_scrgb_result);
	checked_roundtrip(&probe, "version 2 Windows-scRGB description");
	require_condition(version2_scrgb_result.ready && !version2_scrgb_result.failed,
		"version 2 Windows-scRGB image description was not ready");

	struct description_result scrgb_result = {0};
	struct description_result bt2100_result = {0};
	struct wp_image_description_v1 *scrgb =
		wp_color_manager_v1_create_windows_scrgb(probe.manager);
	struct wp_image_description_v1 *bt2100 =
		wp_color_manager_v1_create_windows_bt2100(probe.manager);
	wp_image_description_v1_add_listener(scrgb, &description_listener, &scrgb_result);
	wp_image_description_v1_add_listener(bt2100, &description_listener, &bt2100_result);
	checked_roundtrip(&probe, "predefined Windows image descriptions");
	require_condition(scrgb_result.ready && !scrgb_result.failed,
		"Windows-scRGB image description was not ready");
	require_condition(bt2100_result.ready && !bt2100_result.failed,
		"Windows-BT.2100 image description was not ready");
	require_condition(scrgb_result.identity != 0 && bt2100_result.identity != 0,
		"predefined image description identity was zero");
	require_condition(scrgb_result.identity != bt2100_result.identity,
		"different Windows image descriptions shared an identity");

	struct wl_surface *surface = wl_compositor_create_surface(probe.compositor);
	struct wp_color_management_surface_v1 *color_surface =
		wp_color_manager_v1_get_surface(probe.manager, surface);
	wp_color_management_surface_v1_set_image_description(color_surface, scrgb,
		WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL);
	wl_surface_commit(surface);
	checked_roundtrip(&probe, "Windows-scRGB surface commit");
	wp_color_management_surface_v1_set_image_description(color_surface, bt2100,
		WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL);
	wl_surface_commit(surface);
	checked_roundtrip(&probe, "Windows-BT.2100 surface commit");

	struct wp_color_management_output_v1 *color_output =
		wp_color_manager_v1_get_output(probe.manager, probe.output);
	struct description_result output_description_result = {0};
	struct wp_image_description_v1 *output_description =
		wp_color_management_output_v1_get_image_description(color_output);
	wp_image_description_v1_add_listener(output_description,
		&description_listener, &output_description_result);
	checked_roundtrip(&probe, "output image description");
	require_condition(output_description_result.ready && !output_description_result.failed,
		"headless output image description was not ready");

	struct output_information output_info = {0};
	struct wp_image_description_info_v1 *information =
		wp_image_description_v1_get_information(output_description);
	wp_image_description_info_v1_add_listener(information,
		&information_listener, &output_info);
	checked_roundtrip(&probe, "output image-description information");
	require_condition(output_info.done, "output image-description information was incomplete");
	require_condition(output_info.saw_primaries && output_info.saw_primaries_named,
		"output primary color volume was incomplete");
	require_condition(output_info.primaries_named == WP_COLOR_MANAGER_V1_PRIMARIES_SRGB,
		"headless SDR output did not report sRGB primaries");
	require_condition(output_info.saw_tf_named &&
		output_info.tf_named == WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_GAMMA22,
		"headless SDR output did not report gamma 2.2");
	require_condition(output_info.saw_luminances && output_info.min_lum == 2000 &&
		output_info.max_lum == 80 && output_info.reference_lum == 80,
		"SDR output luminances changed or falsely advertise HDR headroom");
	require_condition(output_info.saw_target_primaries && output_info.saw_target_luminance,
		"output target color volume was incomplete");
	require_condition(output_info.target_min_lum == 2000 && output_info.target_max_lum == 80,
		"headless SDR output target luminance changed");
	require_condition(!output_info.saw_max_cll && !output_info.saw_max_fall,
		"SDR output unexpectedly reported HDR content-light metadata");

	wp_color_management_surface_v1_unset_image_description(color_surface);
	wl_surface_commit(surface);
	checked_roundtrip(&probe, "surface image-description reset");

	wp_image_description_v1_destroy(output_description);
	wp_color_management_output_v1_destroy(color_output);
	wp_color_management_surface_v1_destroy(color_surface);
	wl_surface_destroy(surface);
	wp_image_description_v1_destroy(bt2100);
	wp_image_description_v1_destroy(scrgb);
	wp_image_description_v1_destroy(version2_scrgb);
	wp_color_manager_v1_destroy(version2.manager);
	wp_image_description_v1_destroy(version1_output_description);
	wp_color_management_output_v1_destroy(version1_color_output);
	wp_image_description_v1_destroy(version1_scrgb);
	wp_color_manager_v1_destroy(version1.manager);
	wp_color_manager_v1_destroy(probe.manager);
	wl_output_release(probe.output);
	wl_compositor_destroy(probe.compositor);
	wl_registry_destroy(probe.registry);
	wl_display_disconnect(probe.display);

	puts("PASS: color-management-v1 Proton-EM v1 and Windows HDR v3 wire contracts");
	return EXIT_SUCCESS;
}

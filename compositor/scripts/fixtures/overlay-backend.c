// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#include <assert.h>
#include <drm_fourcc.h>
#include <inttypes.h>
#include <libliftoff.h>
#include <math.h>
#include <string.h>
#include <wlr/render/dmabuf.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/util/log.h>
#include "backend/drm/drm.h"
#include "backend/drm/fb.h"

struct liftoff_layer {
	bool has_fence;
	uint64_t fence;
};
static struct wlr_drm_layer overlay;
static uint64_t properties[16];
static uint32_t buffer_format = DRM_FORMAT_XRGB2101010;
static bool fail_fence;
static unsigned destroyed;

void liftoff_layer_destroy(struct liftoff_layer *layer) { assert(layer); destroyed++; }
void liftoff_output_destroy(struct liftoff_output *output) { assert(output); destroyed++; }
void liftoff_plane_destroy(struct liftoff_plane *plane) { assert(plane); destroyed++; }
void liftoff_device_destroy(struct liftoff_device *device) { assert(device); destroyed++; }

int liftoff_layer_set_property(struct liftoff_layer *layer, const char *name, uint64_t value) {
	if (strcmp(name, "IN_FENCE_FD") == 0) {
		if (fail_fence) return -1;
		layer->has_fence = true;
		layer->fence = value;
	}
	return 0;
}
void liftoff_layer_unset_property(struct liftoff_layer *layer, const char *name) {
	assert(strcmp(name, "IN_FENCE_FD") == 0);
	layer->has_fence = false;
}
void liftoff_layer_set_fb_composited(struct liftoff_layer *layer) {}
int drmModeAtomicAddProperty(drmModeAtomicReq *req, uint32_t object, uint32_t property, uint64_t value) {
	assert(property < 16);
	properties[property] = value;
	return 0;
}
bool wlr_buffer_get_dmabuf(struct wlr_buffer *buffer, struct wlr_dmabuf_attributes *attrs) {
	attrs->format = buffer_format;
	return true;
}
struct wlr_drm_layer *get_drm_layer(struct wlr_drm_backend *drm, struct wlr_output_layer *layer) {
	return &overlay;
}
bool drm_connector_is_cursor_visible(struct wlr_drm_connector *conn) { return false; }
bool create_fb_damage_clips_blob(struct wlr_drm_backend *drm, int width, int height,
		const pixman_region32_t *damage, uint32_t *blob_id) { return false; }

#include "overlay-functions.h"

int main(void) {
	struct wlr_buffer buffer = {.width = 1920, .height = 1080};
	struct wlr_drm_fb fb = {.wlr_buf = &buffer, .id = 1};
	struct liftoff_layer primary = {0}, composition = {0}, layer = {0};
	struct wlr_drm_plane plane = {.liftoff_layer = &primary};
	struct wlr_drm_crtc crtc = {
		.id = 1, .primary = &plane, .liftoff_composition_layer = &composition,
		.props = {.mode_id = 1, .active = 2},
	};
	wl_list_init(&crtc.layers);
	struct wlr_drm_backend drm = {.liftoff_fallback_allowed = true};
	struct wlr_drm_connector conn = {
		.backend = &drm, .crtc = &crtc, .id = 2,
		.props = {.crtc_id = 3, .max_bpc = 4, .colorspace = 5, .hdr_output_metadata = 6},
		.max_bpc_bounds = {8, 12},
	};
	struct wlr_output_layer_state layer_state = {0};
	struct wlr_output_state base = {.layers = &layer_state, .layers_len = 1};
	struct wlr_drm_connector_state state = {
		.connector = &conn, .base = &base, .active = true, .primary_fb = &fb,
		.colorspace = 9, .hdr_output_metadata = 42, .primary_in_fence_fd = 7,
	};
	struct wlr_drm_device_state device = {.connectors = &state, .connectors_len = 1};
	struct wl_array damage = {0};

	// Startup recovery must never commit a frame with an omitted candidate,
	// or change backend after real scanout has begun.
	assert(can_fallback_from_liftoff(&drm, &device));
	layer_state.buffer = &buffer;
	assert(!can_fallback_from_liftoff(&drm, &device));
	layer_state.buffer = NULL;
	layer_state.must_scan_out = true;
	assert(!can_fallback_from_liftoff(&drm, &device));
	layer_state.must_scan_out = false;
	drm.liftoff_fallback_allowed = false;
	assert(!can_fallback_from_liftoff(&drm, &device));

	// HDR requires both connector metadata and 10-bit transport.
	assert(add_connector(NULL, &state, true, &damage));
	assert(properties[4] == 10 && properties[5] == 9 && properties[6] == 42);
	assert(primary.has_fence && composition.has_fence && primary.fence == 7);
	conn.max_bpc_bounds[1] = 8;
	assert(drm_atomic_pick_max_bpc(&conn, &fb) == 8);
	conn.max_bpc_bounds[1] = 12;

	// Returning to SDR clears metadata and both retained primary fences.
	buffer_format = DRM_FORMAT_XRGB8888;
	state.colorspace = 0;
	state.hdr_output_metadata = 0;
	state.primary_in_fence_fd = -1;
	assert(add_connector(NULL, &state, true, &damage));
	assert(properties[4] == 8 && properties[5] == 0 && properties[6] == 0);
	assert(!primary.has_fence && !composition.has_fence);

	// Explicit sync -> implicit sync -> demotion must not reuse a closed FD.
	overlay.liftoff = &layer;
	overlay.pending_fb = &fb;
	overlay.pending_in_fence_fd = 11;
	layer_state.buffer = &buffer;
	assert(set_layer_props(&drm, &layer_state, 1, &damage));
	assert(layer.has_fence && layer.fence == 11);
	overlay.pending_in_fence_fd = -1;
	assert(set_layer_props(&drm, &layer_state, 1, &damage));
	assert(!layer.has_fence);
	overlay.pending_in_fence_fd = 12;
	assert(set_layer_props(&drm, &layer_state, 1, &damage));
	layer_state.buffer = NULL;
	overlay.pending_in_fence_fd = -1;
	assert(set_layer_props(&drm, &layer_state, 1, &damage));
	assert(!layer.has_fence);

	// Property failures propagate so the caller can compose the window.
	fail_fence = true;
	overlay.pending_in_fence_fd = 13;
	assert(!set_layer_props(&drm, &layer_state, 1, &damage));
	state.primary_in_fence_fd = 14;
	assert(!add_connector(NULL, &state, false, &damage));

	// Partially initialized libliftoff resources can be torn down once and
	// every capability pointer is cleared before atomic fallback.
	drm.crtcs = &crtc;
	drm.num_crtcs = 1;
	drm.planes = &plane;
	drm.num_planes = 1;
	drm.liftoff = (void *)&device;
	crtc.liftoff = (void *)&state;
	plane.liftoff = (void *)&fb;
	finish(&drm);
	assert(destroyed == 5);
	assert(!drm.liftoff && !crtc.liftoff && !crtc.liftoff_composition_layer);
	assert(!plane.liftoff && !plane.liftoff_layer);
	finish(&drm);
	assert(destroyed == 5);
	wl_array_release(&damage);
	return 0;
}

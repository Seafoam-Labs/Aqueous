// SPDX-License-Identifier: MIT
#include <assert.h>
#include <limits.h>
#include <libliftoff.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/backend/headless.h>
#include <wlr/render/dmabuf.h>
#include <wlr/render/swapchain.h>
#include <wlr/types/wlr_scene.h>
#include "backend/drm/drm.h"
#include "backend/drm/fb.h"
#include "render/color_pipeline.h"

static unsigned live_blobs, created_blobs, destroyed_sources, cap_calls;
static int fail_blob_after = -1, fail_property_after = -1;
static bool cursor_visible, cyclic, unknown_mandatory, cap_failure;
static uint64_t written[128][16];
static struct drm_color_ctm_3x4 last_matrix;

// Distinct DRM fds model a mixed NVIDIA/AMD/Intel machine.
drmVersion *drmGetVersion(int fd) {
	if (fd == 104) return NULL;
	const char *driver = fd == 100 ? "nvidia-drm" : fd == 101 ? "nouveau" :
		fd == 102 ? "i915" : fd == 103 ? "xe" : "amdgpu";
	drmVersion *version = calloc(1, sizeof(*version));
	assert(version);
	version->name = strdup(driver);
	assert(version->name);
	version->name_len = strlen(driver);
	return version;
}
void drmFreeVersion(drmVersion *version) {
	if (!version) return;
	free(version->name);
	free(version);
}

const struct wlr_drm_interface legacy_iface = {0};
const struct wlr_drm_interface atomic_iface = {0};
bool drm_connector_is_cursor_visible(struct wlr_drm_connector *conn) { return cursor_visible; }
struct wlr_color_transform_lut_3x1d *color_transform_lut_3x1d_from_base(struct wlr_color_transform *tr) {
	assert(tr->type == COLOR_TRANSFORM_LUT_3X1D);
	struct wlr_color_transform_lut_3x1d *lut = wl_container_of(tr, lut, base);
	return lut;
}
int drmSetClientCap(int fd, uint64_t capability, uint64_t value) {
	assert(capability == DRM_CLIENT_CAP_PLANE_COLOR_PIPELINE && value == 1);
	cap_calls++;
	return cap_failure ? -1 : 0;
}
int drmModeCreatePropertyBlob(int fd, const void *data, size_t size, uint32_t *id) {
	if (fail_blob_after == 0) return -1;
	if (fail_blob_after > 0) fail_blob_after--;
	if (size == sizeof(last_matrix)) memcpy(&last_matrix, data, size);
	*id = ++created_blobs;
	live_blobs++;
	return 0;
}
int drmModeDestroyPropertyBlob(int fd, uint32_t id) {
	assert(id && live_blobs);
	live_blobs--;
	return 0;
}
int drmModeAtomicAddProperty(drmModeAtomicReq *req, uint32_t object, uint32_t prop, uint64_t value) {
	if (fail_property_after == 0) return -1;
	if (fail_property_after > 0) fail_property_after--;
	assert(object < 128 && prop < 16);
	written[object][prop] = value;
	return 0;
}

/* Three nodes: decode, matrix, encode. Enum values are deliberately >31. */
drmModeObjectProperties *drmModeObjectGetProperties(int fd, uint32_t id, uint32_t type) {
	drmModeObjectProperties *p = calloc(1, sizeof(*p));
	p->count_props = type == DRM_MODE_OBJECT_PLANE ? 1 : 5;
	p->props = calloc(p->count_props, sizeof(*p->props));
	p->prop_values = calloc(p->count_props, sizeof(*p->prop_values));
	if (type == DRM_MODE_OBJECT_PLANE) {
		p->props[0] = 1;
		return p;
	}
	assert(id >= 10 && id <= 12);
	p->props[0] = 2; // TYPE
	p->prop_values[0] = id == 11 ? DRM_COLOROP_CTM_3X4 : DRM_COLOROP_1D_CURVE;
	if (unknown_mandatory && id == 11) p->prop_values[0] = 999;
	p->props[1] = 3; // NEXT
	p->prop_values[1] = id == 12 ? (cyclic ? 10 : 0) : id + 1;
	p->props[2] = 4; // DATA
	p->props[3] = 5; // CURVE_1D_TYPE
	p->props[4] = 6; // SIZE
	p->prop_values[4] = 2;
	return p;
}
void drmModeFreeObjectProperties(drmModeObjectProperties *p) {
	if (!p) return;
	free(p->props); free(p->prop_values); free(p);
}
drmModePropertyRes *drmModeGetProperty(int fd, uint32_t id) {
	static const char *names[] = {"", "COLOR_PIPELINE", "TYPE", "NEXT", "DATA", "CURVE_1D_TYPE", "SIZE"};
	assert(id < sizeof(names) / sizeof(names[0]));
	drmModePropertyRes *p = calloc(1, sizeof(*p));
	p->prop_id = id;
	snprintf(p->name, sizeof(p->name), "%s", names[id]);
	p->flags = DRM_MODE_PROP_ENUM;
	if (id == 3 || id == 6) p->flags = DRM_MODE_PROP_RANGE | DRM_MODE_PROP_IMMUTABLE;
	if (id == 4) p->flags = DRM_MODE_PROP_BLOB;
	if (id == 1 || id == 5) {
		p->count_enums = 2;
		p->enums = calloc(2, sizeof(*p->enums));
		p->enums[0].value = id == 1 ? 0 : 70;
		p->enums[1].value = id == 1 ? 10 : 71;
		snprintf(p->enums[0].name, sizeof(p->enums[0].name), "%s", id == 1 ? "Bypass" : "sRGB EOTF");
		snprintf(p->enums[1].name, sizeof(p->enums[1].name), "%s", id == 1 ? "Pipeline 10" : "Gamma 2.2 Inverse");
	}
	return p;
}
void drmModeFreeProperty(drmModePropertyRes *p) {
	if (!p) return;
	free(p->values); free(p->enums); free(p->blob_ids); free(p);
}

/* Compile the exact production implementation rather than a matching mock. */
#include "render/color_pipeline.c"
#include "backend/drm/color_pipeline.c"

struct liftoff_plane { uint32_t id; };
struct liftoff_layer { struct liftoff_plane *plane; bool compose; };
struct liftoff_plane *liftoff_layer_get_plane(struct liftoff_layer *layer) { return layer->plane; }
uint32_t liftoff_plane_get_id(struct liftoff_plane *plane) { return plane->id; }
bool liftoff_layer_needs_composition(struct liftoff_layer *layer) { return layer->compose; }
#include "liftoff-color.h"

static void source_destroy(struct wlr_buffer *b) { destroyed_sources++; }
static const struct wlr_buffer_impl source_impl = { .destroy = source_destroy };

static void numeric(void) {
	uint64_t u;
	assert(color_pipeline_fixed(1, &u) && u == UINT64_C(0x100000000));
	assert(color_pipeline_fixed(-1.5, &u) && u == UINT64_C(0x8000000180000000));
	assert(color_pipeline_fixed(-0.0, &u) && u == 0);
	assert(!color_pipeline_fixed(INFINITY, &u));
	assert(!color_pipeline_fixed(NAN, &u));
	assert(!color_pipeline_fixed(2147483648.0, &u));
	struct color_pipeline_recipe recipe = {0};
	assert(!color_pipeline_add_decode(&recipe, WLR_COLOR_TRANSFER_FUNCTION_BT1886));
	assert(color_pipeline_add_decode(&recipe, WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ));
	const float matrix[9] = {2, 0, 0, 0, 3, 0, 0, 0, 4};
	assert(color_pipeline_add_matrix(&recipe, matrix));
	struct wlr_color_transform *encode = wlr_color_transform_init_linear_to_inverse_eotf(WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ);
	assert(encode && color_pipeline_add_transform(&recipe, encode));
	wlr_color_transform_unref(encode);
	normalize(&recipe);
	assert(recipe.len == 3);
	assert(strcmp(recipe.ops[0].curve, "PQ 125 EOTF") == 0);
	assert(strcmp(recipe.ops[2].curve, "PQ 125 Inverse EOTF") == 0);
	assert(fabs(recipe.ops[1].matrix[0] - 2) < 1e-12);
	assert(fabs(recipe.ops[1].matrix[5] - 3) < 1e-12);
	assert(fabs(recipe.ops[1].matrix[10] - 4) < 1e-12);
	struct color_pipeline_recipe identical = recipe;
	assert(color_pipeline_fingerprint(&recipe) == color_pipeline_fingerprint(&identical));
	identical.ops[1].matrix[0] += 0.01;
	assert(color_pipeline_fingerprint(&recipe) != color_pipeline_fingerprint(&identical));
	// These matrices do not commute: R' = 2R + 2G, G' = 3G.
	struct color_pipeline_recipe ordered = {0};
	const float mix[9] = {1, 1, 0, 0, 1, 0, 0, 0, 1};
	assert(color_pipeline_add_matrix(&ordered, mix));
	assert(color_pipeline_add_matrix(&ordered, matrix));
	normalize(&ordered);
	assert(ordered.len == 1);
	assert(ordered.ops[0].matrix[0] == 2 && ordered.ops[0].matrix[1] == 2);
	assert(ordered.ops[0].matrix[5] == 3 && ordered.ops[0].matrix[10] == 4);
	uint16_t samples[] = {0, UINT16_MAX, 0, 0, UINT16_MAX, 0, 0, UINT16_MAX, 0};
	struct wlr_color_transform_lut_3x1d lut = { .dim = 3, .lut_3x1d = samples };
	assert(lut_resample_qualified(&lut, 5));
	assert(!lut_resample_qualified(&lut, 2));
	assert(!lut_resample_qualified(&lut, 1));
	assert(lut_resample(samples, 3, 5, 2) == UINT32_MAX);
	assert(lut_resample(samples, 3, 5, 4) == 0);
}

static void scene_resources(void) {
	struct wl_event_loop *loop = wl_event_loop_create();
	assert(loop);
	struct wlr_backend *backend = wlr_headless_backend_create(loop);
	assert(backend);
	struct wlr_output *output = wlr_headless_add_output(backend, 64, 64);
	struct wlr_scene *scene = wlr_scene_create();
	assert(output && scene);
	struct wlr_scene_output *so = wlr_scene_output_create(scene, output);
	assert(so);
	unsigned before = destroyed_sources;
	// Give the real scene destructor ownership of a swapchain buffer and a
	// transform; teardown must release both without a GPU or renderer.
	struct wlr_buffer buffer;
	wlr_buffer_init(&buffer, &source_impl, 64, 64);
	so->color_pipeline_swapchain = calloc(1, sizeof(*so->color_pipeline_swapchain));
	assert(so->color_pipeline_swapchain);
	wl_list_init(&so->color_pipeline_swapchain->allocator_destroy.link);
	so->color_pipeline_swapchain->slots[0].buffer = &buffer;
	so->color_pipeline_identity = wlr_color_transform_init_linear_to_inverse_eotf(
		WLR_COLOR_TRANSFER_FUNCTION_EXT_LINEAR);
	assert(so->color_pipeline_identity);
	struct wlr_color_transform *identity = wlr_color_transform_ref(so->color_pipeline_identity);
	wlr_scene_output_destroy(so);
	assert(destroyed_sources == before + 1);
	assert(identity->ref_count == 1);
	wlr_color_transform_unref(identity);
	wlr_scene_node_destroy(&scene->tree.node);
	wlr_backend_destroy(backend);
	wl_event_loop_destroy(loop);
}

int main(void) {
	numeric();
	// NVIDIA must never negotiate the capability, including an explicit auto.
	const char *modes[] = {NULL, "auto", "off"};
	for (size_t mode = 0; mode < sizeof(modes) / sizeof(modes[0]); mode++) {
		if (modes[mode]) setenv("AQUEOUS_DRM_COLOR_PIPELINE", modes[mode], 1);
		else unsetenv("AQUEOUS_DRM_COLOR_PIPELINE");
		for (int fd = 99; fd <= 104; fd++) {
			struct wlr_drm_backend backend = { .fd = fd, .iface = &atomic_iface };
			cap_calls = 0;
			drm_color_pipeline_init(&backend);
			bool enabled = mode != 2 && (fd == 99 || fd == 102 || fd == 103);
			assert(backend.color_pipeline_enabled == enabled);
			assert(cap_calls == (enabled ? 1u : 0u));
		}
	}
	cap_calls = 0;
	puts("PASS: NVIDIA/nouveau skip capability negotiation; AMD/Intel remain eligible; unknown driver stays disabled");
	struct wlr_drm_plane plane = { .id = 2 };
	struct wlr_drm_crtc crtc = { .id = 3 };
	struct wlr_drm_backend drm = { .fd = -1, .planes = &plane, .num_planes = 1 };
	struct wlr_drm_connector conn = { .backend = &drm, .crtc = &crtc };
	struct wlr_drm_connector_state state = { .connector = &conn };
	unsetenv("AQUEOUS_DRM_COLOR_PIPELINE");
	cap_failure = true;
	drm_color_pipeline_init(&drm);
	assert(cap_calls == 1 && !drm.color_pipeline_enabled);
	cap_failure = false;
	drm_color_pipeline_init(&drm);
	assert(cap_calls == 2 && drm.color_pipeline_enabled);
	// Model a fresh backend: startup policy never toggles a live DRM fd.
	drm.color_pipeline_enabled = false;
	cap_calls = 0;
	setenv("AQUEOUS_DRM_COLOR_PIPELINE", "off", 1);
	drm_color_pipeline_init(&drm);
	assert(!cap_calls && !drm.color_pipeline_enabled);
	setenv("AQUEOUS_DRM_COLOR_PIPELINE", "auto", 1);
	cap_failure = true;
	drm_color_pipeline_init(&drm);
	assert(!drm.color_pipeline_enabled);
	cap_failure = false;
	drm_color_pipeline_init(&drm);
	assert(drm.color_pipeline_enabled);
	drm_color_pipeline_discover(&drm, &plane);
	assert(plane.color_pipeline && plane.color_pipeline->len == 1);
	drm_color_pipeline_finish(&plane);
	cyclic = true;
	drm_color_pipeline_discover(&drm, &plane);
	assert(plane.color_pipeline && plane.color_pipeline->len == 0);
	drm_color_pipeline_finish(&plane);
	cyclic = false;
	drm_color_pipeline_discover(&drm, &plane);

	struct color_pipeline_recipe recipe = {0};
	assert(color_pipeline_add_decode(&recipe, WLR_COLOR_TRANSFER_FUNCTION_SRGB));
	const float matrix[9] = {1, 0.25, 0, 0, 1, 0, 0, 0, 1};
	assert(color_pipeline_add_matrix(&recipe, matrix));
	struct wlr_color_transform *encode = wlr_color_transform_init_linear_to_inverse_eotf(WLR_COLOR_TRANSFER_FUNCTION_GAMMA22);
	assert(encode && color_pipeline_add_transform(&recipe, encode));
	wlr_color_transform_unref(encode);
	struct wlr_buffer source;
	wlr_buffer_init(&source, &source_impl, 64, 64);
	struct wlr_buffer *buffer = color_pipeline_wrap(&source, &recipe);
	assert(buffer && source.n_locks == 1 && wlr_buffer_has_color_pipeline(buffer));
	wlr_buffer_drop(&source);
	assert(!destroyed_sources);
	for (unsigned i = 0; i < 512; i++) {
		assert(drm_color_pipeline_add(&state, NULL, &plane, buffer));
		assert(live_blobs == 1);
		assert(written[plane.id][1] == 10);
		assert(written[10][5] == 70 && written[12][5] == 71);
		assert(last_matrix.matrix[1] == UINT64_C(1) << 30);
		drm_color_pipeline_state_finish(&state, false); // TEST_ONLY
		assert(!live_blobs && !state.color_pipeline_state.size);
	}
	fail_blob_after = 0;
	assert(!drm_color_pipeline_add(&state, NULL, &plane, buffer));
	drm_color_pipeline_state_finish(&state, false);
	assert(!live_blobs);
	fail_blob_after = -1;
	fail_property_after = 3; // fail encode after matrix blob creation
	assert(!drm_color_pipeline_add(&state, NULL, &plane, buffer));
	drm_color_pipeline_state_finish(&state, false);
	assert(!live_blobs);
	fail_property_after = -1;
	cursor_visible = true;
	assert(!drm_color_pipeline_add(&state, NULL, &plane, buffer));
	cursor_visible = false;
	assert(drm_color_pipeline_add(&state, NULL, &plane, buffer));
	drm_color_pipeline_state_finish(&state, true);
	assert(!live_blobs && plane.color_pipeline->committed_root == 10);
	assert(drm_color_pipeline_reset(&state, NULL));
	assert(written[plane.id][1] == 0);
	assert(drm_color_pipeline_add(&state, NULL, &plane, NULL));
	drm_color_pipeline_state_finish(&state, true);
	assert(plane.color_pipeline->committed_root == 0);

	// The nominal primary and the assigned physical plane are different.
	struct liftoff_plane physical = { .id = plane.id };
	struct liftoff_layer primary = { .plane = &physical };
	struct wlr_drm_plane nominal = { .id = 100, .liftoff_layer = &primary };
	struct wlr_drm_fb fb = { .wlr_buf = buffer };
	struct wlr_output_state base = {0};
	crtc.primary = &nominal;
	wl_list_init(&crtc.layers);
	state.base = &base;
	state.active = true;
	state.primary_fb = &fb;
	assert(add_color_pipelines(&state, NULL));
	assert(written[plane.id][1] == 10 && written[nominal.id][1] == 0);
	drm_color_pipeline_state_finish(&state, false);
	// The old owner appears after the new owner in a multi-output commit.
	// Its reset must not erase the newly programmed color conversion.
	struct wlr_drm_crtc old_crtc = { .id = 4 };
	struct wlr_drm_connector old_conn = { .backend = &drm, .crtc = &old_crtc };
	plane.color_pipeline->committed_crtc = old_crtc.id;
	plane.color_pipeline->committed_root = 10;
	struct wlr_drm_connector_state connectors[] = {state, { .connector = &old_conn }};
	struct wlr_drm_device_state device = { .connectors = connectors, .connectors_len = 2 };
	assert(reset_device_color_pipelines(&device, NULL));
	assert(written[plane.id][1] == 0);
	assert(add_device_color_pipelines(&device, NULL));
	assert(written[plane.id][1] == 10);
	drm_color_pipeline_state_finish(&connectors[0], true);
	drm_color_pipeline_state_finish(&connectors[1], true);
	assert(plane.color_pipeline->committed_crtc == crtc.id);
	assert(plane.color_pipeline->committed_root == 10 && !live_blobs);
	physical.id = 101; // unmapped hardware must not inherit the nominal recipe
	assert(!add_color_pipelines(&state, NULL));
	drm_color_pipeline_state_finish(&state, false);
	physical.id = plane.id;
	// Test current-layer reuse when an output update does not supply new layers.
	struct wlr_drm_fb uncolored = { .wlr_buf = &source };
	state.primary_fb = &uncolored;
	struct liftoff_layer overlay = { .plane = &physical };
	primary.plane = NULL;
	struct wlr_drm_layer layer = { .liftoff = &overlay, .current_fb = &fb };
	wl_list_insert(&crtc.layers, &layer.link);
	assert(add_color_pipelines(&state, NULL));
	assert(live_blobs == 1);
	drm_color_pipeline_state_finish(&state, false);
	wl_list_remove(&layer.link);
	assert(!live_blobs);

	// Unknown nodes may be bypassed, but cannot substitute for an operation.
	struct color_pipeline pipeline = { .len = 2, .nodes = {
		{ .type = 999, .bypass = 7 }, { .type = DRM_COLOROP_CTM_3X4, .data = 4 },
	} };
	struct color_pipeline_recipe one_matrix = {0};
	assert(color_pipeline_add_matrix(&one_matrix, matrix));
	int assignment[MAX_NODES];
	unsigned budget = 100;
	assert(match(&pipeline, &one_matrix, 0, 0, assignment, &budget));
	assert(assignment[0] == -1 && assignment[1] == 0);
	pipeline.nodes[0].bypass = 0;
	budget = 100;
	assert(!match(&pipeline, &one_matrix, 0, 0, assignment, &budget));

	drm_color_pipeline_finish(&plane);
	unknown_mandatory = true;
	drm_color_pipeline_discover(&drm, &plane);
	assert(!drm_color_pipeline_add(&state, NULL, &plane, buffer));
	assert(!live_blobs);
	drm_color_pipeline_finish(&plane);
	wlr_buffer_drop(buffer);
	assert(destroyed_sources == 1);
	scene_resources();
	puts("PASS: 512 speculative commits, failure cleanup, plane assignment, retained overlays, bypass, LUT resampling, PQ normalization");
}

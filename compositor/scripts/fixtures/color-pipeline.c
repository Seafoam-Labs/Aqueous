// SPDX-License-Identifier: MIT
#include <assert.h>
#include <drm_fourcc.h>
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
static bool cursor_visible, cyclic, unknown_mandatory, cap_failure, cursor_post_blend;
static uint64_t written[256][192];
static struct drm_color_ctm_3x4 last_matrix;
static struct drm_color_lut32 last_lut[1024];
static size_t last_lut_len;
static uint32_t source_format = DRM_FORMAT_ARGB8888;

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
bool wlr_output_cursor_post_blend(struct wlr_output *output) { return cursor_post_blend; }
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
	if (size == sizeof(last_matrix)) {
		memcpy(&last_matrix, data, size);
	} else if (size <= sizeof(last_lut) && size % sizeof(struct drm_color_lut32) == 0) {
		memcpy(last_lut, data, size);
		last_lut_len = size / sizeof(struct drm_color_lut32);
	}
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
	assert(object < 256 && prop < 192);
	written[object][prop] = value;
	return 0;
}

/* Parameterized mock topology. TOPO_LEGACY keeps the original three-node
 * pipeline (decode, matrix, encode; enum values deliberately >31). The
 * NVIDIA modes reproduce the pipelines discovered on the installed
 * 620.73.04 driver and the earlier 610.43.03/615.71.09 FP shapes; ids are
 * arbitrary and must never matter to the production code. */
enum topo_mode { TOPO_LEGACY, TOPO_NVIDIA_620, TOPO_NVIDIA_610, TOPO_CONTROL };
static enum topo_mode topo_mode;

struct mock_prop {
	char name[32];
	uint32_t flags;
	uint64_t range[2];
	struct { char name[32]; uint64_t value; } enums[8];
	int n_enums;
};
static struct mock_prop mock_props[256];
static size_t mock_prop_count;
struct mock_node_info {
	uint32_t id, type;
	bool bypass;
	uint64_t size;
	uint32_t next;
	int curve; /* 0 none, 1 PQ 125 EOTF, 2 PQ 125 Inverse EOTF */
	uint32_t p_type, p_next, p_bypass, p_curve, p_data, p_size, p_interp, p_mult;
};
static struct mock_node_info mock_nodes[64];
static size_t mock_node_count;
static struct { char name[32]; uint32_t root; } mock_pipes[8];
static size_t mock_pipe_count;

static struct mock_node_info *mock_node(uint32_t id) {
	for (size_t i = 0; i < mock_node_count; i++) {
		if (mock_nodes[i].id == id) return &mock_nodes[i];
	}
	assert(!"unknown mock node");
	return NULL;
}

static uint32_t new_prop(const char *name, uint32_t flags) {
	assert(mock_prop_count < 256);
	struct mock_prop *p = &mock_props[mock_prop_count];
	memset(p, 0, sizeof(*p));
	snprintf(p->name, sizeof(p->name), "%s", name);
	p->flags = flags;
	return (uint32_t)(mock_prop_count++ + 10);
}

static void set_enum(struct mock_prop *p, int i, const char *name, uint64_t value) {
	snprintf(p->enums[i].name, sizeof(p->enums[0].name), "%s", name);
	p->enums[i].value = value;
}

static void add_node(uint32_t id, uint32_t type, bool bypass, int curve, uint64_t size,
	uint32_t next) {
	assert(mock_node_count < 64);
	struct mock_node_info *n = &mock_nodes[mock_node_count++];
	memset(n, 0, sizeof(*n));
	n->id = id; n->type = type; n->bypass = bypass; n->curve = curve;
	n->size = size; n->next = next;
	n->p_type = new_prop("TYPE", DRM_MODE_PROP_ENUM);
	struct mock_prop *tp = &mock_props[n->p_type - 10];
	set_enum(tp, 0, "1D Curve", DRM_COLOROP_1D_CURVE);
	set_enum(tp, 1, "1D LUT", DRM_COLOROP_1D_LUT);
	set_enum(tp, 2, "3x4 Matrix", DRM_COLOROP_CTM_3X4);
	set_enum(tp, 3, "Multiplier", DRM_COLOROP_MULTIPLIER);
	set_enum(tp, 4, "3D LUT", DRM_COLOROP_3D_LUT);
	set_enum(tp, 5, "Vendor Op", 999);
	tp->n_enums = 6;
	n->p_next = new_prop("NEXT", DRM_MODE_PROP_RANGE | DRM_MODE_PROP_IMMUTABLE);
	mock_props[n->p_next - 10].range[1] = UINT32_MAX;
	if (bypass) {
		n->p_bypass = new_prop("BYPASS", DRM_MODE_PROP_RANGE);
		mock_props[n->p_bypass - 10].range[1] = 1;
	}
	if (curve) {
		n->p_curve = new_prop("CURVE_1D_TYPE", DRM_MODE_PROP_ENUM);
		struct mock_prop *cp = &mock_props[n->p_curve - 10];
		set_enum(cp, 0, curve == 1 ? "PQ 125 EOTF" : "PQ 125 Inverse EOTF",
			curve == 1 ? 70 : 71);
		cp->n_enums = 1;
	}
	if (type == DRM_COLOROP_1D_LUT) {
		n->p_data = new_prop("DATA", DRM_MODE_PROP_BLOB);
		n->p_size = new_prop("SIZE", DRM_MODE_PROP_RANGE | DRM_MODE_PROP_IMMUTABLE);
		mock_props[n->p_size - 10].range[1] = 65536;
		n->p_interp = new_prop("LUT1D_INTERPOLATION", DRM_MODE_PROP_ENUM);
		struct mock_prop *ip = &mock_props[n->p_interp - 10];
		set_enum(ip, 0, "Linear", 0);
		ip->n_enums = 1;
	} else if (type == DRM_COLOROP_CTM_3X4) {
		n->p_data = new_prop("DATA", DRM_MODE_PROP_BLOB);
	} else if (type == DRM_COLOROP_MULTIPLIER) {
		n->p_mult = new_prop("MULTIPLIER", DRM_MODE_PROP_RANGE);
		mock_props[n->p_mult - 10].range[1] = INT64_MAX;
	}
}

struct nv_spec { uint32_t id, type; bool bypass; int curve; uint64_t size; };
static void add_pipeline(const char *name, const struct nv_spec *specs, size_t len) {
	assert(mock_pipe_count < 8);
	snprintf(mock_pipes[mock_pipe_count].name, sizeof(mock_pipes[0].name), "%s", name);
	mock_pipes[mock_pipe_count].root = specs[0].id;
	mock_pipe_count++;
	for (size_t i = 0; i < len; i++) {
		add_node(specs[i].id, specs[i].type, specs[i].bypass, specs[i].curve, specs[i].size,
			i + 1 < len ? specs[i + 1].id : 0);
	}
}

static const struct nv_spec nv_full[] = {
	{40, DRM_COLOROP_CTM_3X4, true, 0, 0},
	{41, DRM_COLOROP_1D_CURVE, true, 1, 0},
	{42, DRM_COLOROP_1D_LUT, true, 0, 1024},
	{43, DRM_COLOROP_MULTIPLIER, true, 0, 0},
	{44, DRM_COLOROP_CTM_3X4, true, 0, 0},
	{45, DRM_COLOROP_1D_CURVE, false, 2, 0},
	{46, DRM_COLOROP_CTM_3X4, true, 0, 0},
	{47, DRM_COLOROP_1D_LUT, true, 0, 1024},
	{48, DRM_COLOROP_CTM_3X4, true, 0, 0},
	{49, DRM_COLOROP_1D_CURVE, false, 1, 0},
	{50, DRM_COLOROP_CTM_3X4, true, 0, 0},
};
static const struct nv_spec nv_lite[] = {
	{52, DRM_COLOROP_CTM_3X4, true, 0, 0},
	{53, DRM_COLOROP_1D_CURVE, true, 1, 0},
	{54, DRM_COLOROP_1D_LUT, true, 0, 1024},
	{55, DRM_COLOROP_MULTIPLIER, true, 0, 0},
	{56, DRM_COLOROP_CTM_3X4, true, 0, 0},
};
static const struct nv_spec nv_fp_full_620[] = {
	{60, DRM_COLOROP_CTM_3X4, true, 0, 0},
	{61, DRM_COLOROP_1D_CURVE, false, 2, 0},
	{62, DRM_COLOROP_CTM_3X4, true, 0, 0},
	{63, DRM_COLOROP_1D_LUT, true, 0, 1024},
	{64, DRM_COLOROP_CTM_3X4, true, 0, 0},
	{65, DRM_COLOROP_1D_CURVE, false, 1, 0},
	{66, DRM_COLOROP_CTM_3X4, true, 0, 0},
};
static const struct nv_spec nv_fp_full_610[] = {
	{60, DRM_COLOROP_CTM_3X4, true, 0, 0},
	{61, DRM_COLOROP_CTM_3X4, true, 0, 0},
	{62, DRM_COLOROP_1D_CURVE, false, 2, 0},
	{63, DRM_COLOROP_CTM_3X4, true, 0, 0},
	{64, DRM_COLOROP_1D_LUT, true, 0, 1024},
	{65, DRM_COLOROP_CTM_3X4, true, 0, 0},
	{66, DRM_COLOROP_1D_CURVE, false, 1, 0},
	{67, DRM_COLOROP_CTM_3X4, true, 0, 0},
};
static const struct nv_spec nv_fp_lite_620[] = {
	{68, DRM_COLOROP_CTM_3X4, true, 0, 0},
};
static const struct nv_spec nv_fp_lite_610[] = {
	{68, DRM_COLOROP_CTM_3X4, true, 0, 0},
	{69, DRM_COLOROP_CTM_3X4, true, 0, 0},
};
static const struct nv_spec nv_control[] = {
	{80, DRM_COLOROP_CTM_3X4, false, 0, 0},
	{81, DRM_COLOROP_1D_LUT, false, 0, 1024},
	{82, DRM_COLOROP_MULTIPLIER, false, 0, 0},
};

static void topo_build(void) {
	mock_prop_count = 0; mock_node_count = 0; mock_pipe_count = 0;
	switch (topo_mode) {
	case TOPO_NVIDIA_620:
		add_pipeline("NVIDIA Full", nv_full, 11);
		add_pipeline("NVIDIA Lite", nv_lite, 5);
		add_pipeline("NVIDIA FP Full", nv_fp_full_620, 7);
		add_pipeline("NVIDIA FP Lite", nv_fp_lite_620, 1);
		break;
	case TOPO_NVIDIA_610:
		add_pipeline("NVIDIA Full", nv_full, 11);
		add_pipeline("NVIDIA Lite", nv_lite, 5);
		add_pipeline("NVIDIA FP Full", nv_fp_full_610, 8);
		add_pipeline("NVIDIA FP Lite", nv_fp_lite_610, 2);
		break;
	case TOPO_CONTROL:
		add_pipeline("Control", nv_control, 3);
		break;
	default:
		break;
	}
}

/* Legacy topology: three nodes (decode, matrix, encode), enum values >31. */
drmModeObjectProperties *drmModeObjectGetProperties(int fd, uint32_t id, uint32_t type) {
	if (topo_mode != TOPO_LEGACY) {
		drmModeObjectProperties *p = calloc(1, sizeof(*p));
		assert(p);
		if (type == DRM_MODE_OBJECT_PLANE) {
			p->count_props = 1;
			p->props = calloc(1, sizeof(uint32_t));
			p->prop_values = calloc(1, sizeof(uint64_t));
			p->props[0] = 1; // COLOR_PIPELINE
			return p;
		}
		struct mock_node_info *n = NULL;
		for (size_t i = 0; i < mock_node_count; i++) {
			if (mock_nodes[i].id == id) n = &mock_nodes[i];
		}
		if (!n) {
			free(p);
			return NULL;
		}
		uint32_t ids[8];
		uint64_t vals[8];
		size_t k = 0;
		ids[k] = n->p_type; vals[k++] = n->type;
		ids[k] = n->p_next; vals[k++] = n->next;
		if (n->p_bypass) { ids[k] = n->p_bypass; vals[k++] = 1; }
		if (n->p_curve) { ids[k] = n->p_curve; vals[k++] = n->curve == 1 ? 70 : 71; }
		if (n->p_data) { ids[k] = n->p_data; vals[k++] = 0; }
		if (n->p_size) { ids[k] = n->p_size; vals[k++] = n->size; }
		if (n->p_interp) { ids[k] = n->p_interp; vals[k++] = 0; }
		if (n->p_mult) { ids[k] = n->p_mult; vals[k++] = UINT64_C(1) << 32; }
		p->count_props = k;
		p->props = calloc(k, sizeof(uint32_t));
		p->prop_values = calloc(k, sizeof(uint64_t));
		assert(p->props && p->prop_values);
		memcpy(p->props, ids, k * sizeof(uint32_t));
		memcpy(p->prop_values, vals, k * sizeof(uint64_t));
		return p;
	}
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
	if (topo_mode != TOPO_LEGACY) {
		drmModePropertyRes *p = calloc(1, sizeof(*p));
		assert(p);
		p->prop_id = id;
		p->flags = DRM_MODE_PROP_ENUM;
		if (id == 1) {
			snprintf(p->name, sizeof(p->name), "COLOR_PIPELINE");
			p->count_enums = 1 + (int)mock_pipe_count;
			p->enums = calloc(p->count_enums, sizeof(*p->enums));
			assert(p->enums);
			p->enums[0].value = 0;
			snprintf(p->enums[0].name, sizeof(p->enums[0].name), "Bypass");
			for (size_t i = 0; i < mock_pipe_count; i++) {
				p->enums[i + 1].value = mock_pipes[i].root;
				snprintf(p->enums[i + 1].name, sizeof(p->enums[0].name), "%s", mock_pipes[i].name);
			}
			return p;
		}
		assert(id >= 10 && id - 10 < mock_prop_count);
		struct mock_prop *m = &mock_props[id - 10];
		snprintf(p->name, sizeof(p->name), "%s", m->name);
		p->flags = m->flags;
		if (m->flags & DRM_MODE_PROP_ENUM) {
			p->count_enums = m->n_enums;
			p->enums = calloc(m->n_enums, sizeof(*p->enums));
			assert(p->enums);
			for (int i = 0; i < m->n_enums; i++) {
				p->enums[i].value = m->enums[i].value;
				snprintf(p->enums[i].name, sizeof(p->enums[0].name), "%s", m->enums[i].name);
			}
		}
		if (m->flags & DRM_MODE_PROP_RANGE) {
			p->count_values = 2;
			p->values = calloc(2, sizeof(uint64_t));
			assert(p->values);
			p->values[0] = m->range[0];
			p->values[1] = m->range[1];
		}
		return p;
	}
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

static bool mock_cursor_post_blend;
static unsigned mock_damage_whole_calls;
static size_t mock_gamma_size = 1024;
void wlr_output_set_cursor_post_blend(struct wlr_output *output, bool post_blend) {
	mock_cursor_post_blend = post_blend;
}
size_t wlr_output_get_gamma_size(struct wlr_output *output) { return mock_gamma_size; }
static void scene_output_damage_whole(struct wlr_scene_output *so) { mock_damage_whole_calls++; }
#include "scene-color.h"

static void source_destroy(struct wlr_buffer *b) { destroyed_sources++; }
static bool source_get_dmabuf(struct wlr_buffer *b, struct wlr_dmabuf_attributes *attrs) {
	memset(attrs, 0, sizeof(*attrs));
	attrs->width = b->width;
	attrs->height = b->height;
	attrs->format = source_format;
	attrs->modifier = DRM_FORMAT_MOD_INVALID;
	attrs->n_planes = 1;
	attrs->fd[0] = -1;
	return true;
}
static const struct wlr_buffer_impl source_impl = {
	.destroy = source_destroy,
	.get_dmabuf = source_get_dmabuf,
};

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

static void nvidia_planner(void) {
	struct wlr_drm_plane plane = { .id = 2 };
	struct wlr_drm_crtc crtc = { .id = 3 };
	struct wlr_drm_backend drm = { .fd = 100, .planes = &plane, .num_planes = 1,
		.color_pipeline_enabled = true };
	struct wlr_drm_connector conn = { .backend = &drm, .crtc = &crtc };
	struct wlr_drm_connector_state state = { .connector = &conn };
	const float ident[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
	uint64_t fixed;
	struct node_plan out[MAX_NODES];

	topo_mode = TOPO_NVIDIA_620;
	topo_build();
	assert(drm_color_pipeline_discover(&drm, &plane));
	struct color_plane *cp = plane.color_pipeline;
	assert(cp && cp->len == 4);
	assert(!strcmp(cp->pipelines[0].name, "NVIDIA Full") && cp->pipelines[0].len == 11);
	assert(!strcmp(cp->pipelines[1].name, "NVIDIA Lite") && cp->pipelines[1].len == 5);
	assert(!strcmp(cp->pipelines[2].name, "NVIDIA FP Full") && cp->pipelines[2].len == 7);
	assert(!strcmp(cp->pipelines[3].name, "NVIDIA FP Lite") && cp->pipelines[3].len == 1);

	// Encode-ending recipes are inexpressible on all four pipelines: the
	// curve ops lack SDR curves and every pipeline ends in linear light.
	struct color_pipeline_recipe enc = {0};
	assert(color_pipeline_add_decode(&enc, WLR_COLOR_TRANSFER_FUNCTION_SRGB));
	assert(color_pipeline_add_matrix(&enc, ident));
	struct wlr_color_transform *pq_enc =
		wlr_color_transform_init_linear_to_inverse_eotf(WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ);
	assert(pq_enc && color_pipeline_add_transform(&enc, pq_enc));
	wlr_color_transform_unref(pq_enc);
	struct wlr_buffer enc_src;
	wlr_buffer_init(&enc_src, &source_impl, 64, 64);
	struct wlr_buffer *enc_buf = color_pipeline_wrap(&enc_src, &enc);
	assert(enc_buf);
	wlr_buffer_drop(&enc_src);
	assert(!drm_color_pipeline_add(&state, NULL, &plane, enc_buf));
	drm_color_pipeline_state_finish(&state, false);
	wlr_buffer_drop(enc_buf);

	// A linear-ending PQ decode resolves on Lite with the named curve (cost 0
	// beats LUT synthesis); wrap() folded the 1/125 normalization into the
	// matrix, which lands on the trailing matrix op.
	struct color_pipeline_recipe lin = {0};
	assert(color_pipeline_add_decode(&lin, WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ));
	assert(color_pipeline_add_matrix(&lin, ident));
	struct wlr_buffer lin_src;
	wlr_buffer_init(&lin_src, &source_impl, 64, 64);
	struct wlr_buffer *lin_buf = color_pipeline_wrap(&lin_src, &lin);
	assert(lin_buf);
	wlr_buffer_drop(&lin_src);
	assert(drm_color_pipeline_add(&state, NULL, &plane, lin_buf));
	assert(written[plane.id][1] == 52);
	assert(written[53][mock_node(53)->p_curve] == 70);
	assert(written[53][mock_node(53)->p_bypass] == 0);
	assert(written[52][mock_node(52)->p_bypass] == 1);
	assert(written[54][mock_node(54)->p_bypass] == 1);
	assert(written[55][mock_node(55)->p_bypass] == 1);
	assert(written[56][mock_node(56)->p_bypass] == 0);
	assert(color_pipeline_fixed(1.0 / 125.0, &fixed) && last_matrix.matrix[0] == fixed);
	assert(last_matrix.matrix[5] == fixed && last_matrix.matrix[10] == fixed);
	assert(last_matrix.matrix[1] == 0);
	drm_color_pipeline_state_finish(&state, true);
	assert(cp->committed_root == 52);
	wlr_buffer_drop(lin_buf);

	// SDR decodes have no named curve on nvidia: the 1D LUT synthesizes them.
	// A following multiplier folds in while the decoded range fits [0,1].
	struct color_pipeline_recipe fold = {0};
	assert(color_pipeline_add_decode(&fold, WLR_COLOR_TRANSFER_FUNCTION_SRGB));
	fold.ops[fold.len++] = (struct color_pipeline_op){ .type = CP_MULTIPLIER, .multiplier = 0.5 };
	assert(plan_pipeline(&cp->pipelines[1], &fold, DRM_FORMAT_ARGB8888, out));
	assert(out[2].action == NODE_LUT_DECODE && out[2].lut_gain == 0.5);
	assert(out[3].action == NODE_BYPASS);
	struct wlr_buffer fold_src;
	wlr_buffer_init(&fold_src, &source_impl, 64, 64);
	struct wlr_buffer *fold_buf = color_pipeline_wrap(&fold_src, &fold);
	assert(fold_buf);
	wlr_buffer_drop(&fold_src);
	assert(drm_color_pipeline_add(&state, NULL, &plane, fold_buf));
	assert(written[plane.id][1] == 52);
	assert(last_lut_len == 1024);
	for (size_t i = 0; i < 1024; i += 256) {
		double v, max;
		assert(curve_decode("sRGB EOTF", (double)i / 1023, &v, &max));
		uint32_t q = (uint32_t)llround(v * 0.5 * UINT32_MAX);
		assert(last_lut[i].red == q && last_lut[i].green == q && last_lut[i].blue == q);
	}
	assert(written[55][mock_node(55)->p_bypass] == 1);
	drm_color_pipeline_state_finish(&state, false);
	wlr_buffer_drop(fold_buf);

	// A gain beyond the LUT's [0,1] output stays pending for the multiplier.
	struct color_pipeline_recipe pend = {0};
	assert(color_pipeline_add_decode(&pend, WLR_COLOR_TRANSFER_FUNCTION_SRGB));
	pend.ops[pend.len++] = (struct color_pipeline_op){ .type = CP_MULTIPLIER, .multiplier = 2.0 };
	assert(plan_pipeline(&cp->pipelines[1], &pend, DRM_FORMAT_ARGB8888, out));
	assert(out[2].action == NODE_LUT_DECODE && out[2].lut_gain == 1.0);
	assert(out[3].action == NODE_MULTIPLIER && out[3].multiplier == 2.0);

	// PQ normalization on a curve-less pipeline: the LUT outputs pq(u)/125 and
	// an explicit 1/125 multiplier folds in; without one, 125 stays pending.
	struct color_pipeline lut_only = { .len = 3, .nodes = {
		{ .type = DRM_COLOROP_1D_LUT, .data = 4, .size = 1024,
		  .interpolation_supported = true, .bypass = 7 },
		{ .type = DRM_COLOROP_MULTIPLIER, .multiplier = 8, .bypass = 7 },
		{ .type = DRM_COLOROP_CTM_3X4, .data = 4, .bypass = 7 },
	} };
	struct color_pipeline_recipe raw = {0};
	assert(color_pipeline_add_decode(&raw, WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ));
	assert(plan_pipeline(&lut_only, &raw, DRM_FORMAT_ARGB8888, out));
	assert(out[0].action == NODE_LUT_DECODE && out[0].lut_gain == 1.0 / 125.0);
	assert(out[1].action == NODE_BYPASS && out[2].action == NODE_BYPASS);
	struct color_pipeline_recipe pq_only = {0};
	assert(color_pipeline_add_decode(&pq_only, WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ));
	pq_only.len = 1; // drop the normalization multiplier
	assert(plan_pipeline(&lut_only, &pq_only, DRM_FORMAT_ARGB8888, out));
	assert(out[0].action == NODE_LUT_DECODE && out[0].lut_gain == 1.0 / 125.0);
	assert(out[1].action == NODE_MULTIPLIER && out[1].multiplier == 125.0);

	// Full's non-bypassable trailing curve pair rejects linear recipes.
	assert(!plan_pipeline(&cp->pipelines[0], &lin, DRM_FORMAT_ARGB8888, out));

	// FP16 on the 620 shapes: non-FP pipelines don't apply, FMT is inert,
	// FP Lite is FMT-only and FP Full has non-bypassable curves => nothing
	// resolves and the buffer stays composited.
	source_format = DRM_FORMAT_XBGR16161616F;
	struct color_pipeline_recipe fp = {0};
	assert(color_pipeline_add_matrix(&fp, ident));
	struct wlr_buffer fp_src;
	wlr_buffer_init(&fp_src, &source_impl, 64, 64);
	struct wlr_buffer *fp_buf = color_pipeline_wrap(&fp_src, &fp);
	assert(fp_buf);
	wlr_buffer_drop(&fp_src);
	for (size_t i = 0; i < 4; i++) {
		assert(!plan_pipeline(&cp->pipelines[i], &fp, DRM_FORMAT_XBGR16161616F, out));
	}
	assert(!drm_color_pipeline_add(&state, NULL, &plane, fp_buf));
	drm_color_pipeline_state_finish(&state, false);
	source_format = DRM_FORMAT_ARGB8888;
	drm_color_pipeline_finish(&plane);
	assert(!live_blobs);

	// FMT effectiveness opt-in: the FMT-only FP Lite pipeline now resolves
	// FP16 matrices, and an adjacent gain folds into the matrix (the composed
	// post-blend recipe shape after normalization). FP Full still rejects
	// curve-less recipes: its two curves are non-bypassable. Non-FP pipelines
	// never apply to FP16. The default stays conservative and reversible.
	source_format = DRM_FORMAT_XBGR16161616F;
	assert(drm_color_pipeline_discover(&drm, &plane));
	cp = plane.color_pipeline;
	drm_color_pipeline_set_fp16_fmt(true);
	assert(plan_pipeline(&cp->pipelines[3], &fp, DRM_FORMAT_XBGR16161616F, out));
	assert(out[0].action == NODE_MATRIX);
	struct color_pipeline_recipe fpg = {0};
	assert(color_pipeline_add_matrix(&fpg, ident));
	fpg.ops[fpg.len++] = (struct color_pipeline_op){ .type = CP_MULTIPLIER, .multiplier = 2.0 };
	normalize(&fpg);
	assert(fpg.len == 1 && fpg.ops[0].type == CP_MATRIX);
	assert(plan_pipeline(&cp->pipelines[3], &fpg, DRM_FORMAT_XBGR16161616F, out));
	assert(out[0].action == NODE_MATRIX && out[0].matrix[0] == 2.0);
	for (size_t i = 0; i < 3; i++) {
		assert(!plan_pipeline(&cp->pipelines[i], &fp, DRM_FORMAT_XBGR16161616F, out));
	}
	assert(drm_color_pipeline_add(&state, NULL, &plane, fp_buf));
	drm_color_pipeline_state_finish(&state, false);
	drm_color_pipeline_set_fp16_fmt(false);
	for (size_t i = 0; i < 4; i++) {
		assert(!plan_pipeline(&cp->pipelines[i], &fp, DRM_FORMAT_XBGR16161616F, out));
	}
	drm_color_pipeline_finish(&plane);
	assert(!live_blobs);
	source_format = DRM_FORMAT_ARGB8888;

	// 610/615 FP shapes: FP16 gain/gamut lands on the second matrix (CSC11)
	// with FMT bypassed; for integer formats FMT is effective.
	topo_mode = TOPO_NVIDIA_610;
	topo_build();
	assert(drm_color_pipeline_discover(&drm, &plane));
	cp = plane.color_pipeline;
	assert(cp && cp->len == 4);
	assert(cp->pipelines[2].len == 8 && cp->pipelines[3].len == 2);
	assert(plan_pipeline(&cp->pipelines[3], &fp, DRM_FORMAT_XBGR16161616F, out));
	assert(out[0].action == NODE_BYPASS && out[1].action == NODE_MATRIX);
	assert(plan_pipeline(&cp->pipelines[3], &fp, DRM_FORMAT_ARGB8888, out));
	assert(out[0].action == NODE_MATRIX);
	source_format = DRM_FORMAT_XBGR16161616F;
	assert(drm_color_pipeline_add(&state, NULL, &plane, fp_buf));
	assert(written[plane.id][1] == 68);
	assert(written[68][mock_node(68)->p_bypass] == 1);
	assert(written[69][mock_node(69)->p_bypass] == 0);
	assert(color_pipeline_fixed(1.0, &fixed) && last_matrix.matrix[0] == fixed);
	drm_color_pipeline_state_finish(&state, false);
	source_format = DRM_FORMAT_ARGB8888;
	wlr_buffer_drop(fp_buf);
	drm_color_pipeline_finish(&plane);
	assert(!live_blobs);

	// Non-bypassable matrix/LUT/multiplier ops are programmed to identity
	// when unused; a non-bypassable curve would reject the pipeline instead.
	topo_mode = TOPO_CONTROL;
	topo_build();
	assert(drm_color_pipeline_discover(&drm, &plane));
	cp = plane.color_pipeline;
	assert(cp && cp->len == 1 && cp->pipelines[0].len == 3);
	struct color_pipeline_recipe ctl = {0};
	const float mix[9] = {1, 0.25, 0, 0, 1, 0, 0, 0, 1};
	assert(color_pipeline_add_matrix(&ctl, mix));
	struct wlr_buffer ctl_src;
	wlr_buffer_init(&ctl_src, &source_impl, 64, 64);
	struct wlr_buffer *ctl_buf = color_pipeline_wrap(&ctl_src, &ctl);
	assert(ctl_buf);
	wlr_buffer_drop(&ctl_src);
	assert(drm_color_pipeline_add(&state, NULL, &plane, ctl_buf));
	assert(written[plane.id][1] == 80);
	assert(last_matrix.matrix[1] == UINT64_C(1) << 30); // 0.25 in S31.32
	assert(last_lut_len == 1024);
	for (size_t i = 0; i < 1024; i += 256) {
		uint32_t q = (uint32_t)llround((double)i / 1023 * UINT32_MAX);
		assert(last_lut[i].red == q);
	}
	assert(color_pipeline_fixed(1.0, &fixed) && written[82][mock_node(82)->p_mult] == fixed);
	drm_color_pipeline_state_finish(&state, false);
	wlr_buffer_drop(ctl_buf);
	drm_color_pipeline_finish(&plane);
	assert(!live_blobs);

	topo_mode = TOPO_LEGACY;
	puts("PASS: nvidia 620/610 topology, LUT decode synthesis, gain folding, FP16 effectiveness + FMT opt-in, identity programming");
}

static void post_blend(void) {
	// Encode LUT knots match the kernel curves exactly.
	struct wlr_color_transform *lut = color_pipeline_encode_lut(
		WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ, 12.5, 1024);
	assert(lut);
	struct wlr_color_transform_lut_3x1d *l = color_transform_lut_3x1d_from_base(lut);
	assert(l->dim == 1024);
	for (size_t i = 0; i < 1024; i += 512) {
		double v;
		assert(curve_encode_eval("PQ 125 Inverse EOTF", (double)i / 1023 * 12.5, &v));
		uint16_t q = (uint16_t)llround(v * UINT16_MAX);
		assert(l->lut_3x1d[i] == q && l->lut_3x1d[1024 + i] == q && l->lut_3x1d[2048 + i] == q);
	}
	double v;
	assert(curve_encode_eval("PQ 125 Inverse EOTF", 12.5, &v));
	assert(l->lut_3x1d[1023] == (uint16_t)llround(v * UINT16_MAX));
	wlr_color_transform_unref(lut);
	lut = color_pipeline_encode_lut(WLR_COLOR_TRANSFER_FUNCTION_SRGB, 1.0, 256);
	assert(lut);
	l = color_transform_lut_3x1d_from_base(lut);
	assert(l->lut_3x1d[0] == 0 && l->lut_3x1d[255] == UINT16_MAX);
	wlr_color_transform_unref(lut);
	assert(!color_pipeline_encode_lut(WLR_COLOR_TRANSFER_FUNCTION_EXT_LINEAR, 1.0, 256));
	assert(!color_pipeline_encode_lut(WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ, 0.0, 256));
	assert(!color_pipeline_encode_lut(WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ, 12.5, 1));

	// Retarget strips the encode, keeps the PQ normalization, appends 1/linear_max.
	struct color_pipeline_recipe r = {0};
	assert(color_pipeline_add_decode(&r, WLR_COLOR_TRANSFER_FUNCTION_SRGB));
	const float ident[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
	const float gain[9] = {0.01f, 0, 0, 0, 0.01f, 0, 0, 0, 0.01f};
	assert(color_pipeline_add_matrix(&r, gain));
	struct wlr_color_transform *enc =
		wlr_color_transform_init_linear_to_inverse_eotf(WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ);
	assert(enc && color_pipeline_add_transform(&r, enc));
	wlr_color_transform_unref(enc);
	enum wlr_color_transfer_function tf;
	assert(color_pipeline_retarget_linear(&r, 12.5, &tf) &&
		tf == WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ);
	assert(r.ops[r.len - 1].type == CP_MULTIPLIER && r.ops[r.len - 1].multiplier == 1.0 / 12.5);
	assert(r.ops[r.len - 2].type == CP_MULTIPLIER && r.ops[r.len - 2].multiplier == 125.0);
	assert(!color_pipeline_retarget_linear(&r, 12.5, &tf)); // now ends in a multiplier
	assert(!color_pipeline_retarget_linear(&r, 0.0, &tf));
	struct color_pipeline_recipe bad = {0};
	assert(color_pipeline_add_matrix(&bad, gain));
	assert(!color_pipeline_retarget_linear(&bad, 12.5, &tf));

	// The retargeted recipe resolves on NVIDIA Lite (620): sRGB decode in the
	// LUT, the normalized linear gain on the trailing matrix, no plane encode.
	topo_mode = TOPO_NVIDIA_620;
	topo_build();
	struct wlr_drm_plane plane = { .id = 2 };
	struct wlr_drm_crtc crtc = { .id = 3 };
	struct wlr_drm_backend drm = { .fd = 100, .planes = &plane, .num_planes = 1,
		.color_pipeline_enabled = true };
	struct wlr_drm_connector conn = { .backend = &drm, .crtc = &crtc };
	struct wlr_drm_connector_state state = { .connector = &conn };
	assert(drm_color_pipeline_discover(&drm, &plane));
	struct wlr_buffer src;
	wlr_buffer_init(&src, &source_impl, 64, 64);
	struct wlr_buffer *buf = color_pipeline_wrap(&src, &r);
	assert(buf);
	wlr_buffer_drop(&src);
	assert(drm_color_pipeline_add(&state, NULL, &plane, buf));
	assert(written[plane.id][1] == 52);
	uint64_t fixed;
	double expect = (1.0 / 12.5) * (125.0 * (double)gain[0]);
	assert(color_pipeline_fixed(expect, &fixed) && last_matrix.matrix[0] == fixed);
	assert(written[55][mock_node(55)->p_bypass] == 1);
	drm_color_pipeline_state_finish(&state, false);
	wlr_buffer_drop(buf);

	// The cursor mode must match the conversion kind: post-blend frames apply
	// the CRTC gamma LUT to the cursor plane and need it linearized; plane-only
	// frames need the wire-encoded cursor.
	struct wlr_buffer pb_src;
	wlr_buffer_init(&pb_src, &source_impl, 64, 64);
	struct wlr_buffer *pb_buf = color_pipeline_wrap_post_blend(&pb_src, &r);
	assert(pb_buf && color_pipeline_is_post_blend(pb_buf));
	wlr_buffer_drop(&pb_src);
	struct color_pipeline_recipe plain = {0};
	assert(color_pipeline_add_decode(&plain, WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ));
	assert(color_pipeline_add_matrix(&plain, ident));
	struct wlr_buffer pl_src;
	wlr_buffer_init(&pl_src, &source_impl, 64, 64);
	struct wlr_buffer *pl_buf = color_pipeline_wrap(&pl_src, &plain);
	assert(pl_buf && !color_pipeline_is_post_blend(pl_buf));
	wlr_buffer_drop(&pl_src);
	cursor_visible = true;
	cursor_post_blend = false;
	assert(!drm_color_pipeline_add(&state, NULL, &plane, pb_buf));
	cursor_post_blend = true;
	assert(drm_color_pipeline_add(&state, NULL, &plane, pb_buf));
	drm_color_pipeline_state_finish(&state, false);
	assert(!drm_color_pipeline_add(&state, NULL, &plane, pl_buf));
	cursor_post_blend = false;
	assert(drm_color_pipeline_add(&state, NULL, &plane, pl_buf));
	drm_color_pipeline_state_finish(&state, false);
	cursor_visible = false;
	wlr_buffer_drop(pb_buf);
	wlr_buffer_drop(pl_buf);

	drm_color_pipeline_finish(&plane);
	assert(!live_blobs);
	topo_mode = TOPO_LEGACY;

	// Gamma blob cache: stable ID while contents match, rollback keeps the
	// committed cache, replacement and reset transfer ownership exactly once.
	struct wlr_drm_backend gdrm = { .fd = 99 };
	struct wlr_drm_crtc gcrtc = { .id = 90, .props.gamma_lut = 5 };
	uint16_t rampA[12] = {0, 100, 200, 65535, 0, 100, 200, 65535, 0, 100, 200, 65535};
	uint16_t rampB[12] = {0, 300, 600, 65535, 0, 300, 600, 65535, 0, 300, 600, 65535};
	uint32_t id1 = 0, id2 = 0, id3 = 0;
	bool cached = true;
	assert(drm_color_gamma_lut_blob(&gdrm, &gcrtc, 4, rampA, &id1, &cached) && !cached && id1);
	drm_color_gamma_lut_apply(&gdrm, &gcrtc, id1, cached, 4, rampA);
	assert(gcrtc.gamma_lut == id1 && live_blobs == 1);
	unsigned created_before = created_blobs;
	for (unsigned i = 0; i < 512; i++) {
		uint32_t id = 0;
		assert(drm_color_gamma_lut_blob(&gdrm, &gcrtc, 4, rampA, &id, &cached));
		assert(cached && id == id1 && created_blobs == created_before);
		drm_color_gamma_lut_apply(&gdrm, &gcrtc, id, cached, 4, rampA);
		drm_color_gamma_lut_rollback(&gdrm, &gcrtc, id, cached);
		assert(live_blobs == 1);
	}
	// Changed contents: a failed test must not destroy the committed cache.
	assert(drm_color_gamma_lut_blob(&gdrm, &gcrtc, 4, rampB, &id2, &cached) && !cached && id2 != id1);
	drm_color_gamma_lut_rollback(&gdrm, &gcrtc, id2, cached);
	assert(live_blobs == 1 && gcrtc.gamma_lut == id1);
	assert(drm_color_gamma_lut_blob(&gdrm, &gcrtc, 4, rampB, &id3, &cached) && !cached);
	drm_color_gamma_lut_apply(&gdrm, &gcrtc, id3, cached, 4, rampB);
	assert(gcrtc.gamma_lut == id3 && live_blobs == 1);
	assert(drm_color_gamma_lut_blob(&gdrm, &gcrtc, 4, rampB, &id2, &cached) && cached && id2 == id3);
	// Reset releases the blob and the snapshot.
	uint32_t zero = 1;
	assert(drm_color_gamma_lut_blob(&gdrm, &gcrtc, 0, NULL, &zero, &cached) && !cached && zero == 0);
	drm_color_gamma_lut_apply(&gdrm, &gcrtc, zero, cached, 0, NULL);
	assert(gcrtc.gamma_lut == 0 && !gcrtc.gamma_lut_data && !live_blobs);
	// Teardown releases a committed blob.
	assert(drm_color_gamma_lut_blob(&gdrm, &gcrtc, 4, rampA, &id1, &cached) && !cached);
	drm_color_gamma_lut_apply(&gdrm, &gcrtc, id1, cached, 4, rampA);
	drm_color_gamma_lut_finish(&gdrm, &gcrtc);
	assert(!gcrtc.gamma_lut && !gcrtc.gamma_lut_data && !live_blobs);
	puts("PASS: post-blend encode LUT, linear retarget, gamma blob stability and ownership");
}

static void scene_post_blend(void) {
	struct wlr_scene_output *so = calloc(1, sizeof(*so));
	struct wlr_output *output = calloc(1, sizeof(*output));
	assert(so && output);
	so->output = output;
	struct wlr_output_state state;
	wlr_output_state_init(&state);
	struct wlr_output_image_description desc = {
		.primaries = WLR_COLOR_NAMED_PRIMARIES_BT2020,
		.transfer_function = WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ,
		.max_cll = 1000,
	};
	double linear_max = 0;
	struct wlr_color_transform *lut = scene_output_encode_lut(so, &desc, &linear_max);
	assert(lut && linear_max == 12.5);
	assert(scene_output_encode_lut(so, &desc, &linear_max) == lut);

	// Engage: owns gamma, cursor linearized, whole damage on the mode flip.
	scene_output_post_blend_state(so, &state, true);
	assert(so->color_pipeline_gamma_owned && so->color_pipeline_post_blend);
	assert(mock_cursor_post_blend && mock_damage_whole_calls == 1);
	assert(!(state.committed & WLR_OUTPUT_STATE_COLOR_TRANSFORM));
	scene_output_post_blend_state(so, &state, true);
	assert(mock_damage_whole_calls == 1);

	// Disengage: commit the gamma reset, cursor back to wire encoding.
	scene_output_post_blend_state(so, &state, false);
	assert(!so->color_pipeline_gamma_owned && !so->color_pipeline_post_blend);
	assert(!mock_cursor_post_blend && mock_damage_whole_calls == 2);
	assert((state.committed & WLR_OUTPUT_STATE_COLOR_TRANSFORM) && !state.color_transform);
	wlr_output_state_finish(&state);
	wlr_output_state_init(&state);
	scene_output_post_blend_state(so, &state, false);
	assert(!(state.committed & WLR_OUTPUT_STATE_COLOR_TRANSFORM));
	assert(mock_damage_whole_calls == 2);

	// The LUT cache tracks peak, transfer function and gamma size exactly.
	desc.max_cll = 400;
	struct wlr_color_transform *lut2 = scene_output_encode_lut(so, &desc, &linear_max);
	assert(lut2 && lut2 != lut && linear_max == 5.0);
	desc.transfer_function = WLR_COLOR_TRANSFER_FUNCTION_EXT_LINEAR;
	assert(!scene_output_encode_lut(so, &desc, &linear_max));
	desc.transfer_function = WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ;
	mock_gamma_size = 0;
	assert(!scene_output_encode_lut(so, &desc, &linear_max));
	mock_gamma_size = 1024;

	wlr_output_state_finish(&state);
	wlr_color_transform_unref(so->color_pipeline_encode_lut);
	free(so);
	free(output);
	puts("PASS: scene post-blend ownership, gamma reset, cursor sync, encode LUT cache");
}

int main(void) {
	numeric();
	// NVIDIA requires the experimental post-blend opt-in; nouveau never qualifies.
	const char *modes[] = {NULL, "auto", "off"};
	for (size_t mode = 0; mode < sizeof(modes) / sizeof(modes[0]); mode++) {
		if (modes[mode]) setenv("AQUEOUS_DRM_COLOR_PIPELINE", modes[mode], 1);
		else unsetenv("AQUEOUS_DRM_COLOR_PIPELINE");
		for (int pb = 0; pb <= 1; pb++) {
			if (pb) setenv("AQUEOUS_DRM_COLOR_PIPELINE_POST_BLEND", "1", 1);
			else unsetenv("AQUEOUS_DRM_COLOR_PIPELINE_POST_BLEND");
			for (int fd = 99; fd <= 104; fd++) {
				struct wlr_drm_backend backend = { .fd = fd, .iface = &atomic_iface };
				cap_calls = 0;
				drm_color_pipeline_init(&backend);
				bool enabled = mode != 2 &&
					(fd == 99 || fd == 102 || fd == 103 || (fd == 100 && pb));
				assert(backend.color_pipeline_enabled == enabled);
				assert(cap_calls == (enabled ? 1u : 0u));
			}
		}
	}
	unsetenv("AQUEOUS_DRM_COLOR_PIPELINE_POST_BLEND");
	setenv("AQUEOUS_DRM_COLOR_PIPELINE_POST_BLEND", "yes", 1);
	struct wlr_drm_backend nv_invalid = { .fd = 100, .iface = &atomic_iface };
	cap_calls = 0;
	drm_color_pipeline_init(&nv_invalid);
	assert(!nv_invalid.color_pipeline_enabled && !cap_calls);
	unsetenv("AQUEOUS_DRM_COLOR_PIPELINE_POST_BLEND");
	cap_calls = 0;
	puts("PASS: NVIDIA requires the post-blend opt-in; nouveau skips; AMD/Intel remain eligible; unknown driver stays disabled");
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
	// An unchanged recipe must keep one DATA blob ID across speculative and
	// real commits. A new ID per commit is a KMS color update on every flip.
	unsigned created_before = created_blobs;
	uint64_t matrix_blob = 0;
	for (unsigned i = 0; i < 512; i++) {
		assert(drm_color_pipeline_add(&state, NULL, &plane, buffer));
		assert(live_blobs == 1 && created_blobs == created_before + 1);
		if (!i) matrix_blob = written[11][4];
		assert(matrix_blob && written[11][4] == matrix_blob);
		assert(written[plane.id][1] == 10);
		assert(written[10][5] == 70 && written[12][5] == 71);
		assert(last_matrix.matrix[1] == UINT64_C(1) << 30);
		drm_color_pipeline_state_finish(&state, i & 1); // alternate TEST_ONLY/real
		assert(live_blobs == 1 && !state.color_pipeline_state.size);
	}
	// Changed contents replace the cached blob; KMS keeps any committed copy.
	struct color_pipeline_recipe changed = {0};
	const float other_matrix[9] = {1, 0.5, 0, 0, 1, 0, 0, 0, 1};
	assert(color_pipeline_add_decode(&changed, WLR_COLOR_TRANSFER_FUNCTION_SRGB));
	assert(color_pipeline_add_matrix(&changed, other_matrix));
	struct wlr_color_transform *other_encode =
		wlr_color_transform_init_linear_to_inverse_eotf(WLR_COLOR_TRANSFER_FUNCTION_GAMMA22);
	assert(other_encode && color_pipeline_add_transform(&changed, other_encode));
	wlr_color_transform_unref(other_encode);
	struct wlr_buffer changed_source;
	wlr_buffer_init(&changed_source, &source_impl, 64, 64);
	struct wlr_buffer *changed_buffer = color_pipeline_wrap(&changed_source, &changed);
	assert(changed_buffer);
	wlr_buffer_drop(&changed_source);
	// Creation failure keeps the previous cached blob and fails the plane.
	fail_blob_after = 0;
	assert(!drm_color_pipeline_add(&state, NULL, &plane, changed_buffer));
	drm_color_pipeline_state_finish(&state, false);
	assert(live_blobs == 1 && created_blobs == created_before + 1);
	fail_blob_after = -1;
	assert(drm_color_pipeline_add(&state, NULL, &plane, changed_buffer));
	assert(live_blobs == 1 && created_blobs == created_before + 2);
	assert(written[11][4] != matrix_blob && last_matrix.matrix[1] == UINT64_C(1) << 31);
	drm_color_pipeline_state_finish(&state, false);
	assert(drm_color_pipeline_add(&state, NULL, &plane, buffer));
	assert(live_blobs == 1 && created_blobs == created_before + 3);
	drm_color_pipeline_state_finish(&state, false);
	wlr_buffer_drop(changed_buffer);
	assert(destroyed_sources == 1);
	fail_property_after = 3; // fail encode after the cached matrix blob
	assert(!drm_color_pipeline_add(&state, NULL, &plane, buffer));
	drm_color_pipeline_state_finish(&state, false);
	assert(live_blobs == 1);
	fail_property_after = -1;
	cursor_visible = true;
	// A plane-only conversion leaves the wire-encoded cursor untouched; a
	// linearized cursor requires the matching post-blend frame.
	assert(drm_color_pipeline_add(&state, NULL, &plane, buffer));
	drm_color_pipeline_state_finish(&state, false);
	cursor_post_blend = true;
	assert(!drm_color_pipeline_add(&state, NULL, &plane, buffer));
	cursor_post_blend = false;
	cursor_visible = false;
	assert(drm_color_pipeline_add(&state, NULL, &plane, buffer));
	drm_color_pipeline_state_finish(&state, true);
	assert(live_blobs == 1 && plane.color_pipeline->committed_root == 10);
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
	assert(plane.color_pipeline->committed_root == 10 && live_blobs == 1);
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
	assert(live_blobs == 1);

	// Unknown nodes may be bypassed, but cannot substitute for an operation.
	struct color_pipeline pipeline = { .len = 2, .nodes = {
		{ .type = 999, .bypass = 7 }, { .type = DRM_COLOROP_CTM_3X4, .data = 4 },
	} };
	struct color_pipeline_recipe one_matrix = {0};
	assert(color_pipeline_add_matrix(&one_matrix, matrix));
	struct node_plan plan_out[MAX_NODES];
	assert(plan_pipeline(&pipeline, &one_matrix, DRM_FORMAT_ARGB8888, plan_out));
	assert(plan_out[0].action == NODE_BYPASS && plan_out[1].action == NODE_MATRIX);
	pipeline.nodes[0].bypass = 0;
	assert(!plan_pipeline(&pipeline, &one_matrix, DRM_FORMAT_ARGB8888, plan_out));

	drm_color_pipeline_finish(&plane);
	assert(!live_blobs); // plane teardown releases cached DATA blobs
	unknown_mandatory = true;
	drm_color_pipeline_discover(&drm, &plane);
	assert(!drm_color_pipeline_add(&state, NULL, &plane, buffer));
	assert(!live_blobs);
	drm_color_pipeline_finish(&plane);
	wlr_buffer_drop(buffer);
	assert(destroyed_sources == 2);
	nvidia_planner();
	post_blend();
	scene_post_blend();
	scene_resources();
	puts("PASS: 512 speculative commits, failure cleanup, plane assignment, retained overlays, bypass, LUT resampling, PQ normalization");
}

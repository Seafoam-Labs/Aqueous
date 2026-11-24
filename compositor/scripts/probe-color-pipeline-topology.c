/* Step 0 read-only color-pipeline topology probe. No commits, no blob
 * creation, no property writes; client caps affect only this fd. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

static void enum_list(const drmModePropertyRes *p, uint64_t cur, char *out, size_t cap) {
	size_t off = 0;
	out[0] = 0;
	for (int i = 0; i < p->count_enums && off + 2 < cap; i++) {
		off += snprintf(out + off, cap - off, "%s%s=%llu%s", i ? ", " : "",
			p->enums[i].name, (unsigned long long)p->enums[i].value,
			p->enums[i].value == cur ? "*" : "");
	}
}

static void walk_pipeline(int fd, uint64_t root, const char *name) {
	uint32_t next = (uint32_t)root, seen[64];
	size_t nseen = 0;
	int idx = 0;
	printf("  pipeline \"%s\" root=%u\n", name, (uint32_t)root);
	while (next) {
		if (nseen >= 64) { printf("    ... >64 nodes, truncated\n"); return; }
		for (size_t i = 0; i < nseen; i++) {
			if (seen[i] == next) { printf("    CYCLE back to %u\n", next); return; }
		}
		seen[nseen++] = next;
		drmModeObjectProperties *props =
			drmModeObjectGetProperties(fd, next, DRM_MODE_OBJECT_COLOROP);
		if (!props) { printf("    node %u: property read FAILED\n", next); return; }
		char type[64] = "?", curves[512] = "", interp[256] = "", extra[256] = "";
		uint32_t next_id = 0;
		unsigned long long size = 0;
		int bypass = 0, mult = 0, data = 0, have_next = 0;
		size_t extra_off = 0;
		for (uint32_t i = 0; i < props->count_props; i++) {
			drmModePropertyRes *p = drmModeGetProperty(fd, props->props[i]);
			if (!p) continue;
			uint64_t v = props->prop_values[i];
			if (!strcmp(p->name, "TYPE")) {
				for (int e = 0; e < p->count_enums; e++) {
					if (p->enums[e].value == v) {
						snprintf(type, sizeof(type), "%s", p->enums[e].name);
					}
				}
			} else if (!strcmp(p->name, "NEXT")) {
				next_id = (uint32_t)v; have_next = 1;
			} else if (!strcmp(p->name, "BYPASS")) {
				bypass = 1;
			} else if (!strcmp(p->name, "CURVE_1D_TYPE")) {
				enum_list(p, v, curves, sizeof(curves));
			} else if (!strcmp(p->name, "SIZE")) {
				size = (unsigned long long)v;
			} else if (!strcmp(p->name, "LUT1D_INTERPOLATION") ||
					   !strcmp(p->name, "LUT3D_INTERPOLATION")) {
				enum_list(p, v, interp, sizeof(interp));
			} else if (!strcmp(p->name, "MULTIPLIER")) {
				mult = 1;
			} else if (!strcmp(p->name, "DATA")) {
				data = 1;
			} else if (extra_off + 2 < sizeof(extra)) {
				extra_off += snprintf(extra + extra_off, sizeof(extra) - extra_off,
					"%s%s", extra_off ? "," : "", p->name);
			}
			drmModeFreeProperty(p);
		}
		drmModeFreeObjectProperties(props);
		printf("    [%2d] id=%-4u %-12s bypass=%s", idx, next, type, bypass ? "yes" : "NO ");
		if (size) printf(" size=%llu", size);
		if (mult) printf(" MULT");
		if (data) printf(" DATA");
		if (curves[0]) printf(" curves={%s}", curves);
		if (interp[0]) printf(" interp={%s}", interp);
		if (extra[0]) printf(" extra={%s}", extra);
		printf("\n");
		if (!have_next) { printf("    node %u has no NEXT property\n", next); return; }
		next = next_id;
		idx++;
	}
	printf("    (%d nodes)\n", idx);
}

int main(int argc, char **argv) {
	const char *path = argc > 1 ? argv[1] : "/dev/dri/card1";
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) { perror(path); return 1; }
	drmVersion *ver = drmGetVersion(fd);
	printf("device %s driver=%s desc=%s version=%d.%d.%d\n", path,
		ver ? ver->name : "?", ver && ver->desc ? ver->desc : "?",
		ver ? ver->version_major : 0, ver ? ver->version_minor : 0,
		ver ? ver->version_patchlevel : 0);
	drmFreeVersion(ver);
	/* Sequential: the kernel requires ATOMIC before PLANE_COLOR_PIPELINE,
	 * and printf argument evaluation order is unspecified. */
	int cap_atomic = drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1);
	int cap_universal = drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
	int cap_color = drmSetClientCap(fd, DRM_CLIENT_CAP_PLANE_COLOR_PIPELINE, 1);
	printf("cap ATOMIC=%d UNIVERSAL_PLANES=%d PLANE_COLOR_PIPELINE=%d (errno=%d)\n",
		cap_atomic, cap_universal, cap_color, cap_color ? errno : 0);

	drmModePlaneRes *planes = drmModeGetPlaneResources(fd);
	if (!planes) { printf("plane resources FAILED\n"); close(fd); return 1; }
	unsigned n_primary = 0, n_overlay = 0, n_cursor = 0, n_pipe_planes = 0, total_pipes = 0;
	for (uint32_t i = 0; i < planes->count_planes; i++) {
		uint32_t id = planes->planes[i];
		drmModeObjectProperties *props =
			drmModeObjectGetProperties(fd, id, DRM_MODE_OBJECT_PLANE);
		if (!props) { printf("plane %u: property read FAILED\n", id); continue; }
		char type[32] = "?";
		drmModePropertyRes *cp = NULL;
		uint64_t cp_cur = 0;
		for (uint32_t j = 0; j < props->count_props; j++) {
			drmModePropertyRes *p = drmModeGetProperty(fd, props->props[j]);
			if (!p) continue;
			if (!strcmp(p->name, "type")) {
				for (int e = 0; e < p->count_enums; e++) {
					if (p->enums[e].value == props->prop_values[j]) {
						snprintf(type, sizeof(type), "%s", p->enums[e].name);
					}
				}
			} else if (!strcmp(p->name, "COLOR_PIPELINE")) {
				cp = p; cp_cur = props->prop_values[j]; p = NULL;
			}
			if (p) drmModeFreeProperty(p);
		}
		drmModeFreeObjectProperties(props);
		if (!strcmp(type, "Primary")) n_primary++;
		else if (!strcmp(type, "Overlay")) n_overlay++;
		else if (!strcmp(type, "Cursor")) n_cursor++;
		printf("plane %u type=%s\n", id, type);
		if (!cp) {
			printf("  no COLOR_PIPELINE property\n");
			continue;
		}
		n_pipe_planes++;
		printf("  COLOR_PIPELINE prop=%u current=%llu entries=%d\n",
			cp->prop_id, (unsigned long long)cp_cur, cp->count_enums);
		for (int e = 0; e < cp->count_enums; e++) {
			printf("  enum \"%s\" = %llu\n", cp->enums[e].name,
				(unsigned long long)cp->enums[e].value);
			if (cp->enums[e].value) {
				total_pipes++;
				walk_pipeline(fd, cp->enums[e].value, cp->enums[e].name);
			}
		}
		drmModeFreeProperty(cp);
	}
	drmModeFreePlaneResources(planes);
	printf("SUMMARY planes: primary=%u overlay=%u cursor=%u; planes-with-pipelines=%u pipelines=%u\n",
		n_primary, n_overlay, n_cursor, n_pipe_planes, total_pipes);

	drmModeRes *res = drmModeGetResources(fd);
	if (res) {
		for (int i = 0; i < res->count_crtcs; i++) {
			uint32_t id = res->crtcs[i];
			drmModeObjectProperties *props =
				drmModeObjectGetProperties(fd, id, DRM_MODE_OBJECT_CRTC);
			if (!props) continue;
			printf("crtc %u color properties:\n", id);
			for (uint32_t j = 0; j < props->count_props; j++) {
				drmModePropertyRes *p = drmModeGetProperty(fd, props->props[j]);
				if (!p) continue;
				if (strcasestr(p->name, "GAMMA") || strcasestr(p->name, "LUT") ||
					strcasestr(p->name, "CTM") || strcasestr(p->name, "COLOR") ||
					strcasestr(p->name, "REGAMMA")) {
					uint64_t v = props->prop_values[j];
					printf("  %s (prop=%u) ", p->name, p->prop_id);
					if (p->flags & DRM_MODE_PROP_ENUM) {
						char buf[256]; enum_list(p, v, buf, sizeof(buf));
						printf("enum {%s}", buf);
					} else if (p->flags & DRM_MODE_PROP_RANGE) {
						printf("range [%llu..%llu] current=%llu",
							(unsigned long long)p->values[0],
							(unsigned long long)p->values[1], (unsigned long long)v);
					} else if (p->flags & DRM_MODE_PROP_BLOB) {
						printf("blob current=%llu", (unsigned long long)v);
					} else {
						printf("flags=0x%x current=%llu", p->flags, (unsigned long long)v);
					}
					printf("\n");
				}
				drmModeFreeProperty(p);
			}
			drmModeFreeObjectProperties(props);
		}
		drmModeFreeResources(res);
	}
	close(fd);
	return 0;
}
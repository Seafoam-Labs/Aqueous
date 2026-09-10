// SPDX-License-Identifier: GPL-3.0-only
#include <stddef.h>
struct wlr_buffer;
struct aqueous_icon_png;
struct aqueous_icon_png *aqueous_icon_png_start(struct wlr_buffer *buffer, int size);
int aqueous_icon_png_fd(struct aqueous_icon_png *job);
const unsigned char *aqueous_icon_png_result(struct aqueous_icon_png *job, size_t *size);
void aqueous_icon_png_destroy(struct aqueous_icon_png *job);

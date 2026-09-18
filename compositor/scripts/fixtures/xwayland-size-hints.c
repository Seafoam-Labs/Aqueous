// The decoder is extracted verbatim from the patched production xwm.c.
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xcb/xcb_icccm.h>

enum { WM_SIZE_HINTS, WLR_DEBUG };
struct wlr_xwm { xcb_atom_t atoms[1]; };
struct wlr_xwayland_surface {
    xcb_size_hints_t *size_hints;
    struct { unsigned set_size_hints; } events;
};
#define wlr_log(level, message) ((void)(level), (void)(message))
static void wl_signal_emit_mutable(unsigned *count, void *data) {
    assert(data == NULL);
    ++*count;
}
#include "decoder.h"

int main(void) {
    struct wlr_xwm xwm = {.atoms = {XCB_ATOM_WM_SIZE_HINTS}};
    struct wlr_xwayland_surface surface = {0};
    struct {
        xcb_get_property_reply_t reply;
        xcb_size_hints_t hints;
    } message = {.reply = {.type = XCB_ATOM_WM_SIZE_HINTS, .format = 32,
        .value_len = 18, .length = 18}};
    _Static_assert(sizeof(xcb_size_hints_t) == 18 * sizeof(uint32_t), "ICCCM hint layout");

    message.hints = (xcb_size_hints_t){
        .flags = XCB_ICCCM_SIZE_HINT_P_MIN_SIZE | XCB_ICCCM_SIZE_HINT_P_MAX_SIZE |
                 XCB_ICCCM_SIZE_HINT_P_RESIZE_INC | XCB_ICCCM_SIZE_HINT_P_ASPECT,
        .min_width = 100, .min_height = 50, .max_width = 1600, .max_height = 900,
        .width_inc = 8, .height_inc = 16, .min_aspect_num = 4, .min_aspect_den = 3,
        .max_aspect_num = 16, .max_aspect_den = 9};
    read_surface_normal_hints(&xwm, &surface, &message.reply);
    assert(surface.events.set_size_hints == 1);
    assert(surface.size_hints->width_inc == 8 && surface.size_hints->height_inc == 16);
    assert(surface.size_hints->min_aspect_num == 4 && surface.size_hints->max_aspect_num == 16);
    assert(surface.size_hints->base_width == 100 && surface.size_hints->base_height == 50);

    // Clients commonly rewrite flags while retaining old values in the struct.
    message.hints.flags = XCB_ICCCM_SIZE_HINT_P_MIN_SIZE;
    read_surface_normal_hints(&xwm, &surface, &message.reply);
    assert(surface.events.set_size_hints == 2);
    assert(surface.size_hints->min_width == 100 && surface.size_hints->max_width == -1);
    assert(surface.size_hints->width_inc == 0 && surface.size_hints->height_inc == 0);
    assert(surface.size_hints->min_aspect_num == 0 && surface.size_hints->min_aspect_den == 0);
    assert(surface.size_hints->max_aspect_num == 0 && surface.size_hints->max_aspect_den == 0);

    message.hints.flags = XCB_ICCCM_SIZE_HINT_BASE_SIZE;
    message.hints.base_width = 80;
    message.hints.base_height = 40;
    read_surface_normal_hints(&xwm, &surface, &message.reply);
    assert(surface.size_hints->min_width == 80 && surface.size_hints->min_height == 40);

    // XDeleteProperty and a zero-length replacement both remove constraints.
    message.reply.type = XCB_ATOM_NONE;
    message.reply.value_len = message.reply.length = 0;
    read_surface_normal_hints(&xwm, &surface, &message.reply);
    assert(surface.size_hints == NULL && surface.events.set_size_hints == 4);
    message.reply.type = XCB_ATOM_WM_SIZE_HINTS;
    read_surface_normal_hints(&xwm, &surface, &message.reply);
    assert(surface.size_hints == NULL && surface.events.set_size_hints == 5);
    puts("PASS XWayland hint flags, fallback sizes, and removal notifications");
    return 0;
}

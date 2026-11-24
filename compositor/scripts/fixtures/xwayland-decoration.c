// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
//
// XWayland SSD negotiation fixture. Window A asks for WM decorations
// (MOTIF decorations=1) and must be suppressed while force_ssd is on, then
// restored when it turns off. Window B insists on its own decorations
// (decorations=0, functions=all) and must never be rewritten.
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xcb/xcb.h>

static xcb_connection_t *conn;
static xcb_atom_t motif;

static xcb_atom_t intern(const char *name) {
    xcb_intern_atom_reply_t *r = xcb_intern_atom_reply(conn,
        xcb_intern_atom(conn, 0, (uint16_t)strlen(name), name), NULL);
    if (!r) { fprintf(stderr, "intern failed\n"); exit(1); }
    xcb_atom_t atom = r->atom;
    free(r);
    return atom;
}

static void set_hints(xcb_window_t win, uint32_t functions, uint32_t decorations) {
    uint32_t hints[5] = { 2, functions, decorations, 0, 0 };
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE, win, motif, motif, 32, 5, hints);
    xcb_flush(conn);
}

// Returns decorations value, or -1 when the property is absent.
static long get_decorations(xcb_window_t win, uint32_t *functions_out) {
    xcb_get_property_reply_t *r = xcb_get_property_reply(conn,
        xcb_get_property(conn, 0, win, motif, XCB_GET_PROPERTY_TYPE_ANY, 0, 5), NULL);
    if (!r) return -1;
    long value = -1;
    if (r->type != XCB_ATOM_NONE && r->format == 32 &&
        xcb_get_property_value_length(r) >= 20) {
        const uint32_t *values = xcb_get_property_value(r);
        if (functions_out) *functions_out = values[1];
        value = (long)values[2];
    }
    free(r);
    return value;
}

static xcb_window_t make_window(xcb_window_t root) {
    xcb_window_t win = xcb_generate_id(conn);
    // A background pixel makes the X server fill the window on map, which is
    // what gives Xwayland content to commit (a bare window never maps).
    uint32_t mask = XCB_CW_EVENT_MASK | XCB_CW_BACK_PIXEL;
    uint32_t values[] = { XCB_EVENT_MASK_PROPERTY_CHANGE | XCB_EVENT_MASK_STRUCTURE_NOTIFY, 0x287858 };
    xcb_create_window(conn, XCB_COPY_FROM_PARENT, win, root, 0, 0, 200, 150, 0,
                      XCB_WINDOW_CLASS_INPUT_OUTPUT, XCB_COPY_FROM_PARENT, mask, values);
    return win;
}

static int wait_decorations(xcb_window_t win, long expected, int seconds) {
    for (int i = 0; i < seconds * 20; i++) {
        long value = get_decorations(win, NULL);
        if (value == expected) return 1;
        usleep(50000);
    }
    return 0;
}

int main(void) {
    conn = xcb_connect(NULL, NULL);
    if (!conn || xcb_connection_has_error(conn)) { fprintf(stderr, "xcb connect failed\n"); return 1; }
    motif = intern("_MOTIF_WM_HINTS");
    xcb_screen_t *screen = xcb_setup_roots_iterator(xcb_get_setup(conn)).data;

    xcb_window_t a = make_window(screen->root);
    xcb_window_t b = make_window(screen->root);
    set_hints(a, 0, 1); // wants WM decorations
    set_hints(b, 0xffffffffu, 0); // insists on its own decorations
    xcb_map_window(conn, a);
    xcb_map_window(conn, b);
    xcb_flush(conn);

    if (!wait_decorations(a, 0, 10)) { fprintf(stderr, "window A never suppressed\n"); return 1; }
    printf("SUPPRESSED\n"); fflush(stdout);

    uint32_t functions = 0;
    long b_deco = get_decorations(b, &functions);
    if (b_deco != 0 || functions != 0xffffffffu) {
        fprintf(stderr, "CSD-insisting window B was rewritten (deco=%ld functions=%u)\n", b_deco, functions);
        return 1;
    }
    printf("CSD-HONORED\n"); fflush(stdout);

    // The test script disables force_ssd here; the original hints must return.
    if (!wait_decorations(a, 1, 10)) { fprintf(stderr, "window A never restored\n"); return 1; }
    printf("RESTORED\n"); fflush(stdout);

    xcb_destroy_window(conn, a);
    xcb_destroy_window(conn, b);
    xcb_flush(conn);
    xcb_disconnect(conn);
    return 0;
}
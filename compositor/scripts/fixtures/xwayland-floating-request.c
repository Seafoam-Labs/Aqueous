// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#define _POSIX_C_SOURCE 200809L

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <wayland-client.h>

#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define BTN_LEFT 0x110u

enum operation {
    OP_MOVE,
    OP_MOVE_UNPRESSED,
    OP_RESIZE_TOP_LEFT,
    OP_RESIZE_BOTTOM_RIGHT,
};

struct app {
    struct wl_display *wayland_display;
    struct wl_registry *registry;
    struct wl_seat *seat;
    struct zwlr_virtual_pointer_manager_v1 *pointer_manager;
    struct zwlr_virtual_pointer_v1 *pointer;
    Display *xdisplay;
    Window root;
    Window window;
    GC gc;
    Atom moveresize;
    const char *sync_dir;
    uint32_t time_msec;
    bool draw_white;
};

static bool sync_path(char *path, size_t size, const struct app *app, const char *name) {
    const int written = snprintf(path, size, "%s/%s", app->sync_dir, name);
    return written >= 0 && (size_t)written < size;
}

static bool marker_exists(const struct app *app, const char *name) {
    char path[PATH_MAX];
    return sync_path(path, sizeof(path), app, name) && access(path, F_OK) == 0;
}

static bool publish_marker(const struct app *app, const char *name) {
    char path[PATH_MAX];
    if (!sync_path(path, sizeof(path), app, name)) return false;
    FILE *file = fopen(path, "w");
    return file != NULL && fclose(file) == 0;
}

static void registry_global(
    void *data,
    struct wl_registry *registry,
    uint32_t name,
    const char *interface,
    uint32_t version) {
    struct app *app = data;
    if (strcmp(interface, wl_seat_interface.name) == 0 && app->seat == NULL) {
        app->seat = wl_registry_bind(
            registry, name, &wl_seat_interface, version < 7 ? version : 7);
    } else if (strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
        app->pointer_manager = wl_registry_bind(
            registry, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
    }
}

static void registry_global_remove(
    void *data,
    struct wl_registry *registry,
    uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static bool wayland_roundtrip(struct app *app) {
    return wl_display_roundtrip(app->wayland_display) >= 0;
}

static bool initialize_wayland(struct app *app) {
    app->wayland_display = wl_display_connect(NULL);
    if (app->wayland_display == NULL) return false;
    app->registry = wl_display_get_registry(app->wayland_display);
    wl_registry_add_listener(app->registry, &registry_listener, app);
    if (!wayland_roundtrip(app) || app->seat == NULL || app->pointer_manager == NULL) {
        return false;
    }
    app->pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(
        app->pointer_manager, app->seat);
    return app->pointer != NULL && wayland_roundtrip(app);
}

static Display *open_xdisplay(void) {
    const struct timespec delay = {.tv_nsec = 50000000};
    for (unsigned int attempt = 0; attempt < 200; attempt++) {
        Display *display = XOpenDisplay(NULL);
        if (display != NULL) return display;
        (void)nanosleep(&delay, NULL);
    }
    return NULL;
}

static bool wait_for_map(struct app *app) {
    const struct timespec delay = {.tv_nsec = 10000000};
    for (unsigned int attempt = 0; attempt < 1000; attempt++) {
        while (XPending(app->xdisplay) != 0) {
            XEvent event;
            XNextEvent(app->xdisplay, &event);
            if (event.type == MapNotify && event.xmap.window == app->window) return true;
        }
        (void)nanosleep(&delay, NULL);
    }
    return false;
}

static bool wait_for_button_press(struct app *app) {
    const struct timespec delay = {.tv_nsec = 1000000};
    for (unsigned int attempt = 0; attempt < 1000; attempt++) {
        while (XPending(app->xdisplay) != 0) {
            XEvent event;
            XNextEvent(app->xdisplay, &event);
            if (event.type == ButtonPress && event.xbutton.window == app->window &&
                event.xbutton.button == Button1) {
                return true;
            }
        }
        (void)nanosleep(&delay, NULL);
    }
    return false;
}

static void redraw_after_configure(struct app *app) {
    bool configured = false;
    unsigned int width = 0;
    unsigned int height = 0;
    XSync(app->xdisplay, False);
    while (XPending(app->xdisplay) != 0) {
        XEvent event;
        XNextEvent(app->xdisplay, &event);
        if (event.type == ConfigureNotify && event.xconfigure.window == app->window) {
            configured = true;
            width = (unsigned int)event.xconfigure.width;
            height = (unsigned int)event.xconfigure.height;
        }
    }
    if (configured) {
        app->draw_white = !app->draw_white;
        XSetForeground(
            app->xdisplay,
            app->gc,
            app->draw_white ? WhitePixel(app->xdisplay, DefaultScreen(app->xdisplay))
                            : BlackPixel(app->xdisplay, DefaultScreen(app->xdisplay)));
        XFillRectangle(app->xdisplay, app->window, app->gc, 0, 0, width, height);
        XFlush(app->xdisplay);
    }
}

static void pointer_motion(
    struct app *app,
    uint32_t x,
    uint32_t y,
    uint32_t width,
    uint32_t height) {
    zwlr_virtual_pointer_v1_motion_absolute(
        app->pointer, ++app->time_msec, x, y, width, height);
    zwlr_virtual_pointer_v1_frame(app->pointer);
}

static void pointer_button(struct app *app, uint32_t state) {
    zwlr_virtual_pointer_v1_button(
        app->pointer, ++app->time_msec, BTN_LEFT, state);
    zwlr_virtual_pointer_v1_frame(app->pointer);
}

static bool send_moveresize(
    struct app *app,
    enum operation operation,
    uint32_t root_x,
    uint32_t root_y) {
    long direction = -1;
    switch (operation) {
        case OP_MOVE:
        case OP_MOVE_UNPRESSED: direction = 8; break;
        case OP_RESIZE_TOP_LEFT: direction = 0; break;
        case OP_RESIZE_BOTTOM_RIGHT: direction = 4; break;
    }

    XEvent message = {0};
    message.xclient.type = ClientMessage;
    message.xclient.window = app->window;
    message.xclient.message_type = app->moveresize;
    message.xclient.format = 32;
    message.xclient.data.l[0] = (long)root_x;
    message.xclient.data.l[1] = (long)root_y;
    message.xclient.data.l[2] = direction;
    message.xclient.data.l[3] = Button1;
    message.xclient.data.l[4] = 1; // Normal application source indication.
    if (XSendEvent(
            app->xdisplay,
            app->root,
            False,
            SubstructureNotifyMask | SubstructureRedirectMask,
            &message) == 0) {
        return false;
    }
    XFlush(app->xdisplay);
    return true;
}

static bool run_operation(
    struct app *app,
    enum operation operation,
    uint32_t start_x,
    uint32_t start_y,
    uint32_t end_x,
    uint32_t end_y,
    uint32_t extent_x,
    uint32_t extent_y) {
    pointer_motion(app, start_x, start_y, extent_x, extent_y);
    if (!wayland_roundtrip(app) || !wayland_roundtrip(app)) return false;

    const bool pressed = operation != OP_MOVE_UNPRESSED;
    if (pressed) {
        pointer_button(app, WL_POINTER_BUTTON_STATE_PRESSED);
        if (!wayland_roundtrip(app) || !wayland_roundtrip(app) ||
            !wait_for_button_press(app)) {
            fprintf(stderr, "FAIL: no X11 button press at request start %u,%u\n", start_x, start_y);
            return false;
        }
    }
    if (!send_moveresize(app, operation, start_x, start_y) ||
        !wayland_roundtrip(app) || !wayland_roundtrip(app)) {
        return false;
    }

    // The X11 ClientMessage reaches the compositor through Xwayland's XWM
    // connection rather than this Wayland connection. Give the resulting
    // management transaction time to take ownership of the pointer before
    // sending the first drag motion.
    const struct timespec management_delay = {.tv_nsec = 50000000};
    (void)nanosleep(&management_delay, NULL);
    if (!wayland_roundtrip(app)) return false;

    pointer_motion(app, end_x, end_y, extent_x, extent_y);
    if (!wayland_roundtrip(app) || !wayland_roundtrip(app)) return false;
    redraw_after_configure(app);
    if (!wayland_roundtrip(app) || !wayland_roundtrip(app)) return false;
    if (pressed) pointer_button(app, WL_POINTER_BUTTON_STATE_RELEASED);
    return wayland_roundtrip(app) && wayland_roundtrip(app);
}

static bool read_request(
    struct app *app,
    enum operation *operation,
    uint32_t *start_x,
    uint32_t *start_y,
    uint32_t *end_x,
    uint32_t *end_y,
    uint32_t *extent_x,
    uint32_t *extent_y) {
    char path[PATH_MAX];
    if (!sync_path(path, sizeof(path), app, "request")) return false;
    FILE *file = fopen(path, "r");
    if (file == NULL) return false;
    char verb[32];
    const int scanned = fscanf(
        file,
        "%31s %u %u %u %u %u %u",
        verb,
        start_x,
        start_y,
        end_x,
        end_y,
        extent_x,
        extent_y);
    const bool closed = fclose(file) == 0;
    if (unlink(path) != 0 || scanned != 7 || !closed || *extent_x == 0 || *extent_y == 0) {
        return false;
    }
    if (strcmp(verb, "move") == 0) {
        *operation = OP_MOVE;
    } else if (strcmp(verb, "move-unpressed") == 0) {
        *operation = OP_MOVE_UNPRESSED;
    } else if (strcmp(verb, "resize-top-left") == 0) {
        *operation = OP_RESIZE_TOP_LEFT;
    } else if (strcmp(verb, "resize-bottom-right") == 0) {
        *operation = OP_RESIZE_BOTTOM_RIGHT;
    } else {
        return false;
    }
    return true;
}

static void destroy_app(struct app *app) {
    if (app->xdisplay != NULL) {
        if (app->gc != NULL) XFreeGC(app->xdisplay, app->gc);
        if (app->window != None) XDestroyWindow(app->xdisplay, app->window);
        XCloseDisplay(app->xdisplay);
    }
    if (app->pointer != NULL) zwlr_virtual_pointer_v1_destroy(app->pointer);
    if (app->pointer_manager != NULL) {
        zwlr_virtual_pointer_manager_v1_destroy(app->pointer_manager);
    }
    if (app->seat != NULL) wl_seat_destroy(app->seat);
    if (app->registry != NULL) wl_registry_destroy(app->registry);
    if (app->wayland_display != NULL) wl_display_disconnect(app->wayland_display);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s SYNC_DIR WM_CLASS\n", argv[0]);
        return 2;
    }
    struct app app = {.sync_dir = argv[1]};
    if (!initialize_wayland(&app)) {
        fprintf(stderr, "FAIL: could not initialize virtual pointer\n");
        destroy_app(&app);
        return 1;
    }
    app.xdisplay = open_xdisplay();
    if (app.xdisplay == NULL) {
        fprintf(stderr, "FAIL: could not connect to DISPLAY=%s\n", getenv("DISPLAY"));
        destroy_app(&app);
        return 1;
    }

    const int screen = DefaultScreen(app.xdisplay);
    app.root = RootWindow(app.xdisplay, screen);
    XSetWindowAttributes attributes = {
        .background_pixel = BlackPixel(app.xdisplay, screen),
        .event_mask = StructureNotifyMask | ButtonPressMask | ButtonReleaseMask,
    };
    app.window = XCreateWindow(
        app.xdisplay,
        app.root,
        100,
        100,
        320,
        200,
        0,
        CopyFromParent,
        InputOutput,
        CopyFromParent,
        CWBackPixel | CWEventMask,
        &attributes);
    app.gc = XCreateGC(app.xdisplay, app.window, 0, NULL);
    if (app.gc == NULL) {
        fprintf(stderr, "FAIL: could not create X11 graphics context\n");
        destroy_app(&app);
        return 1;
    }
    XClassHint class_hint = {.res_name = argv[2], .res_class = argv[2]};
    XSetClassHint(app.xdisplay, app.window, &class_hint);
    XStoreName(app.xdisplay, app.window, argv[2]);
    XWMHints wm_hints = {.flags = InputHint, .input = True};
    XSetWMHints(app.xdisplay, app.window, &wm_hints);
    app.moveresize = XInternAtom(app.xdisplay, "_NET_WM_MOVERESIZE", False);
    XMapRaised(app.xdisplay, app.window);
    XFlush(app.xdisplay);
    if (!wait_for_map(&app)) {
        fprintf(stderr, "FAIL: window did not map\n");
        destroy_app(&app);
        return 1;
    }
    XClearWindow(app.xdisplay, app.window);
    XFlush(app.xdisplay);
    // Let the initial policy placement reach Xwayland and damage the resized
    // X11 pixmap before the harness records its baseline geometry.
    const struct timespec settle_delay = {.tv_nsec = 20000000};
    for (unsigned int attempt = 0; attempt < 25; attempt++) {
        (void)nanosleep(&settle_delay, NULL);
        redraw_after_configure(&app);
        if (!wayland_roundtrip(&app)) {
            fprintf(stderr, "FAIL: Wayland display closed during initial configure\n");
            destroy_app(&app);
            return 1;
        }
    }
    if (!publish_marker(&app, "ready")) {
        fprintf(stderr, "FAIL: could not publish ready marker\n");
        destroy_app(&app);
        return 1;
    }

    const struct timespec delay = {.tv_nsec = 10000000};
    while (!marker_exists(&app, "finish")) {
        if (!marker_exists(&app, "request")) {
            redraw_after_configure(&app);
            (void)nanosleep(&delay, NULL);
            continue;
        }
        enum operation operation;
        uint32_t start_x, start_y, end_x, end_y, extent_x, extent_y;
        if (!read_request(
                &app,
                &operation,
                &start_x,
                &start_y,
                &end_x,
                &end_y,
                &extent_x,
                &extent_y) ||
            !run_operation(
                &app,
                operation,
                start_x,
                start_y,
                end_x,
                end_y,
                extent_x,
                extent_y) ||
            !publish_marker(&app, "done")) {
            fprintf(stderr, "FAIL: interactive request failed\n");
            destroy_app(&app);
            return 1;
        }
    }

    destroy_app(&app);
    return 0;
}

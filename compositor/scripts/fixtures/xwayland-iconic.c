// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
//
// Regression fixture for issue #179: a managed X11 "game" that holds an X11
// keyboard+pointer grab (like SDL/Proton fullscreen games) and minimizes itself
// when it loses focus. On FocusOut it enters iconic state and unmaps its window
// (XIconifyWindow + XUnmapWindow), exactly what Wine/Proton titles do. Like a
// well-behaved SDL client it watches WM_STATE and re-maps when the compositor
// restores it to NormalState. The compositor must keep the window managed as
// minimized across the unmap so it stays in the taskbar/switcher and can be
// cycled back into, rather than dropping it from the desktop.

#define _POSIX_C_SOURCE 200809L

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>

struct wayland_state {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_seat *seat;
    struct zwp_virtual_keyboard_manager_v1 *manager;
    struct zwp_virtual_keyboard_v1 *keyboard;
    struct zwlr_virtual_pointer_manager_v1 *pointer_manager;
    struct zwlr_virtual_pointer_v1 *pointer;
};

static void registry_global(
    void *data, struct wl_registry *registry, uint32_t name,
    const char *interface, uint32_t version) {
    struct wayland_state *state = data;
    if (strcmp(interface, wl_seat_interface.name) == 0 && state->seat == NULL) {
        const uint32_t bind_version = version < 7 ? version : 7;
        state->seat = wl_registry_bind(registry, name, &wl_seat_interface, bind_version);
    } else if (strcmp(interface, zwp_virtual_keyboard_manager_v1_interface.name) == 0) {
        state->manager = wl_registry_bind(registry, name,
            &zwp_virtual_keyboard_manager_v1_interface, 1);
    } else if (strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
        state->pointer_manager = wl_registry_bind(registry, name,
            &zwlr_virtual_pointer_manager_v1_interface, 1);
    }
}

static void registry_global_remove(void *d, struct wl_registry *r, uint32_t n) {
    (void)d; (void)r; (void)n;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static int write_all(int fd, const char *text, size_t size) {
    while (size > 0) {
        const ssize_t written = write(fd, text, size);
        if (written < 0) { if (errno == EINTR) continue; return -1; }
        text += written; size -= (size_t)written;
    }
    return 0;
}

static int create_keymap_fd(size_t *size_out) {
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (context == NULL) return -1;
    struct xkb_keymap *keymap = xkb_keymap_new_from_names(context, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (keymap == NULL) { xkb_context_unref(context); return -1; }
    char *keymap_text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    xkb_keymap_unref(keymap);
    xkb_context_unref(context);
    if (keymap_text == NULL) return -1;
    char path[] = "/tmp/aqueous-virtual-keyboard.XXXXXX";
    const int fd = mkstemp(path);
    if (fd >= 0) unlink(path);
    const size_t size = strlen(keymap_text) + 1;
    if (fd < 0 || write_all(fd, keymap_text, size) != 0 || lseek(fd, 0, SEEK_SET) < 0) {
        if (fd >= 0) close(fd);
        free(keymap_text);
        return -1;
    }
    free(keymap_text);
    *size_out = size;
    return fd;
}

static bool initialize_virtual_input(struct wayland_state *state) {
    state->display = wl_display_connect(NULL);
    if (state->display == NULL) return false;
    state->registry = wl_display_get_registry(state->display);
    wl_registry_add_listener(state->registry, &registry_listener, state);
    if (wl_display_roundtrip(state->display) < 0 || state->seat == NULL ||
        state->manager == NULL || state->pointer_manager == NULL) return false;
    state->keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(state->manager, state->seat);
    state->pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(state->pointer_manager, state->seat);
    size_t keymap_size = 0;
    const int keymap_fd = create_keymap_fd(&keymap_size);
    if (state->keyboard == NULL || state->pointer == NULL || keymap_fd < 0) return false;
    zwp_virtual_keyboard_v1_keymap(state->keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,
        keymap_fd, (uint32_t)keymap_size);
    const int result = wl_display_roundtrip(state->display);
    close(keymap_fd);
    return result >= 0;
}

static double monotonic_seconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) { perror("clock_gettime"); exit(2); }
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static Display *open_display_with_retry(void) {
    const struct timespec delay = {.tv_nsec = 50000000};
    for (int attempt = 0; attempt < 200; attempt++) {
        Display *display = XOpenDisplay(NULL);
        if (display != NULL) return display;
        nanosleep(&delay, NULL);
    }
    return NULL;
}

static uint32_t monotonic_milliseconds(void) {
    return (uint32_t)(monotonic_seconds() * 1000.0);
}

static int xwayland_connection_lost(Display *display) {
    (void)display;
    fprintf(stderr, "CRASHED: lost the connection to Xwayland\n");
    fflush(stderr);
    _exit(1);
}

int main(void) {
    struct wayland_state wayland = {0};
    if (!initialize_virtual_input(&wayland)) {
        fprintf(stderr, "could not create persistent test virtual input devices\n");
        return 2;
    }
    Display *display = open_display_with_retry();
    if (display == NULL) {
        fprintf(stderr, "could not connect to DISPLAY=%s\n", getenv("DISPLAY"));
        return 2;
    }
    XSetIOErrorHandler(xwayland_connection_lost);

    const int screen = DefaultScreen(display);
    const Window root = RootWindow(display, screen);
    XSetWindowAttributes attributes = {
        .background_pixel = BlackPixel(display, screen),
        .border_pixel = WhitePixel(display, screen),
        .event_mask = StructureNotifyMask | FocusChangeMask | ButtonPressMask |
                      ButtonReleaseMask | PointerMotionMask | KeyPressMask | PropertyChangeMask,
        .override_redirect = False,
    };
    const Window window = XCreateWindow(display, root, 100, 100, 500, 350, 1,
        CopyFromParent, InputOutput, CopyFromParent,
        CWBackPixel | CWBorderPixel | CWEventMask | CWOverrideRedirect, &attributes);
    XClassHint class_hint = {
        .res_name = "aqueous-xwayland-iconic-test",
        .res_class = "AqueousXwaylandIconicTest",
    };
    XSetClassHint(display, window, &class_hint);
    XStoreName(display, window, "Aqueous XWayland iconic repro");
    XWMHints wm_hints = {.flags = InputHint, .input = True};
    XSetWMHints(display, window, &wm_hints);

    // Match SDL's Xwayland grab declaration so the compositor honors the grab.
    const Atom may_grab = XInternAtom(display, "_XWAYLAND_MAY_GRAB_KEYBOARD", False);
    XEvent may_grab_message = {0};
    may_grab_message.xclient.type = ClientMessage;
    may_grab_message.xclient.window = window;
    may_grab_message.xclient.message_type = may_grab;
    may_grab_message.xclient.format = 32;
    may_grab_message.xclient.data.l[0] = 1;
    may_grab_message.xclient.data.l[1] = CurrentTime;
    XSendEvent(display, root, False,
        SubstructureNotifyMask | SubstructureRedirectMask, &may_grab_message);

    XMapRaised(display, window);
    XFlush(display);

    const Atom wm_state = XInternAtom(display, "WM_STATE", False);
    bool mapped = false;
    bool currently_mapped = false;
    bool got_focus = false;
    bool iconified = false;
    const double deadline = monotonic_seconds() + 30.0;
    while (monotonic_seconds() < deadline) {
        while (XPending(display) != 0) {
            XEvent event;
            XNextEvent(display, &event);
            if (event.type == MapNotify && !mapped) {
                mapped = true;
                currently_mapped = true;
                printf("READY window=0x%lx\n", window);
                fflush(stdout);
                zwlr_virtual_pointer_v1_motion_absolute(wayland.pointer,
                    monotonic_milliseconds(), 200, 200, 1280, 720);
                zwlr_virtual_pointer_v1_frame(wayland.pointer);
                wl_display_roundtrip(wayland.display);
                XSetInputFocus(display, DefaultRootWindow(display), RevertToPointerRoot, CurrentTime);
                XSync(display, False);
                XGrabPointer(display, window, False,
                    ButtonPressMask | ButtonReleaseMask | PointerMotionMask,
                    GrabModeAsync, GrabModeAsync, window, None, CurrentTime);
                XGrabKeyboard(display, window, False, GrabModeAsync, GrabModeAsync, CurrentTime);
                XSync(display, False);
                continue;
            }
            if (event.type == FocusIn && mapped) {
                if (event.xfocus.mode != NotifyGrab) got_focus = true;
            }
            if (event.type == FocusOut && mapped && got_focus && !iconified) {
                // Ignore transient grab transitions; only a real focus loss
                // (the escape cycle moving focus to a peer) triggers minimize.
                if (event.xfocus.mode == NotifyGrab || event.xfocus.mode == NotifyUngrab) continue;
                printf("FOCUS_OUT mode=%d\n", event.xfocus.mode);
                fflush(stdout);
                iconified = true;
                currently_mapped = false;
                XUngrabKeyboard(display, CurrentTime);
                XUngrabPointer(display, CurrentTime);
                XSync(display, False);
                XIconifyWindow(display, window, screen);
                XUnmapWindow(display, window);
                XSync(display, False);
                printf("ICONIFIED_AND_UNMAPPED\n");
                fflush(stdout);
            }
            if (event.type == KeyPress) {
                printf("KEY keycode=%u\n", event.xkey.keycode);
                fflush(stdout);
            }
            // A well-behaved game (e.g. SDL) watches WM_STATE: when the WM sets
            // NormalState to restore it, it re-maps its window. Only NormalState
            // (1) triggers a re-map; the IconicState (3) write must not.
            if (event.type == PropertyNotify && event.xproperty.atom == wm_state &&
                iconified && !currently_mapped) {
                Atom actual_type;
                int actual_format;
                unsigned long nitems, bytes_after;
                unsigned char *data = NULL;
                if (XGetWindowProperty(display, window, wm_state, 0, 2, False,
                        AnyPropertyType, &actual_type, &actual_format, &nitems,
                        &bytes_after, &data) == Success && data != NULL) {
                    const long state = nitems >= 1 ? ((long *)data)[0] : 0;
                    XFree(data);
                    if (state == NormalState) {
                        printf("RESTORE_REMAP\n");
                        fflush(stdout);
                        currently_mapped = true;
                        iconified = false;
                        got_focus = false;
                        XMapRaised(display, window);
                        XSync(display, False);
                    }
                }
            }
        }
        fd_set read_fds;
        FD_ZERO(&read_fds);
        FD_SET(ConnectionNumber(display), &read_fds);
        struct timeval timeout = {.tv_usec = 50000};
        const int result = select(ConnectionNumber(display) + 1, &read_fds, NULL, NULL, &timeout);
        if (result < 0 && errno != EINTR) { perror("select"); break; }
    }
    XCloseDisplay(display);
    return 0;
}

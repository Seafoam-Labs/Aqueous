// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

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
    void *data,
    struct wl_registry *registry,
    uint32_t name,
    const char *interface,
    uint32_t version) {
    struct wayland_state *state = data;
    if (strcmp(interface, wl_seat_interface.name) == 0 && state->seat == NULL) {
        const uint32_t bind_version = version < 7 ? version : 7;
        state->seat = wl_registry_bind(registry, name, &wl_seat_interface, bind_version);
    } else if (strcmp(interface, zwp_virtual_keyboard_manager_v1_interface.name) == 0) {
        state->manager = wl_registry_bind(
            registry,
            name,
            &zwp_virtual_keyboard_manager_v1_interface,
            1);
    } else if (strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
        state->pointer_manager = wl_registry_bind(
            registry,
            name,
            &zwlr_virtual_pointer_manager_v1_interface,
            1);
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

static int write_all(int fd, const char *text, size_t size) {
    while (size > 0) {
        const ssize_t written = write(fd, text, size);
        if (written < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        text += written;
        size -= (size_t)written;
    }
    return 0;
}

static int create_keymap_fd(size_t *size_out) {
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (context == NULL) return -1;
    struct xkb_keymap *keymap = xkb_keymap_new_from_names(
        context,
        NULL,
        XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (keymap == NULL) {
        xkb_context_unref(context);
        return -1;
    }
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
    if (wl_display_roundtrip(state->display) < 0 ||
        state->seat == NULL || state->manager == NULL || state->pointer_manager == NULL) {
        return false;
    }

    state->keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(
        state->manager,
        state->seat);
    state->pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(
        state->pointer_manager,
        state->seat);
    size_t keymap_size = 0;
    const int keymap_fd = create_keymap_fd(&keymap_size);
    if (state->keyboard == NULL || state->pointer == NULL || keymap_fd < 0) return false;
    zwp_virtual_keyboard_v1_keymap(
        state->keyboard,
        WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,
        keymap_fd,
        (uint32_t)keymap_size);
    const int result = wl_display_roundtrip(state->display);
    close(keymap_fd);
    return result >= 0;
}

static void destroy_virtual_input(struct wayland_state *state) {
    if (state->pointer != NULL) zwlr_virtual_pointer_v1_destroy(state->pointer);
    if (state->pointer_manager != NULL) {
        zwlr_virtual_pointer_manager_v1_destroy(state->pointer_manager);
    }
    if (state->keyboard != NULL) zwp_virtual_keyboard_v1_destroy(state->keyboard);
    if (state->manager != NULL) zwp_virtual_keyboard_manager_v1_destroy(state->manager);
    if (state->seat != NULL) wl_seat_destroy(state->seat);
    if (state->registry != NULL) wl_registry_destroy(state->registry);
    if (state->display != NULL) wl_display_disconnect(state->display);
}

static double monotonic_seconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        perror("clock_gettime");
        exit(2);
    }
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

static void flush_line(const char *line) {
    puts(line);
    fflush(stdout);
}

static uint32_t monotonic_milliseconds(void) {
    return (uint32_t)(monotonic_seconds() * 1000.0);
}

static bool activate_x11_grabs(
    Display *display,
    Window window,
    struct wayland_state *wayland) {
    // Put the cursor inside both the managed and override-redirect fixture
    // geometries using the same virtual-pointer protocol used by wlrctl.
    zwlr_virtual_pointer_v1_motion_absolute(
        wayland->pointer,
        monotonic_milliseconds(),
        200,
        200,
        1280,
        720);
    zwlr_virtual_pointer_v1_frame(wayland->pointer);
    if (wl_display_roundtrip(wayland->display) < 0) return false;
    XSync(display, False);

    // Move X11 focus away first so XGrabKeyboard produces a real
    // FocusIn(mode=Grab) transition for the compositor's grab_focus path.
    XSetInputFocus(display, DefaultRootWindow(display), RevertToPointerRoot, CurrentTime);
    XSync(display, False);

    const int pointer_status = XGrabPointer(
        display,
        window,
        False,
        ButtonPressMask | ButtonReleaseMask | PointerMotionMask,
        GrabModeAsync,
        GrabModeAsync,
        window,
        None,
        CurrentTime);
    const int keyboard_status = XGrabKeyboard(
        display,
        window,
        False,
        GrabModeAsync,
        GrabModeAsync,
        CurrentTime);
    XSync(display, False);
    printf(
        "GRABBED pointer=%d keyboard=%d\n",
        pointer_status,
        keyboard_status);
    fflush(stdout);
    if (pointer_status == GrabSuccess && keyboard_status == GrabSuccess) return true;

    XUngrabPointer(display, CurrentTime);
    XUngrabKeyboard(display, CurrentTime);
    return false;
}

int main(int argc, char **argv) {
    if (argc != 2 ||
        (strcmp(argv[1], "managed") != 0 && strcmp(argv[1], "override") != 0)) {
        fprintf(stderr, "usage: %s managed|override\n", argv[0]);
        return 2;
    }

    const bool override_redirect = strcmp(argv[1], "override") == 0;
    struct wayland_state wayland = {0};
    if (!initialize_virtual_input(&wayland)) {
        fprintf(stderr, "could not create persistent test virtual input devices\n");
        destroy_virtual_input(&wayland);
        return 2;
    }

    Display *display = open_display_with_retry();
    if (display == NULL) {
        fprintf(stderr, "could not connect to DISPLAY=%s\n", getenv("DISPLAY"));
        destroy_virtual_input(&wayland);
        return 2;
    }

    const int screen = DefaultScreen(display);
    const Window root = RootWindow(display, screen);
    XSetWindowAttributes attributes = {
        .background_pixel = BlackPixel(display, screen),
        .border_pixel = WhitePixel(display, screen),
        .event_mask = StructureNotifyMask | FocusChangeMask | ButtonPressMask |
                      ButtonReleaseMask | PointerMotionMask | KeyPressMask,
        .override_redirect = override_redirect ? True : False,
    };
    const unsigned long attribute_mask = CWBackPixel | CWBorderPixel | CWEventMask |
                                         CWOverrideRedirect;
    const Window window = XCreateWindow(
        display,
        root,
        100,
        100,
        500,
        350,
        1,
        CopyFromParent,
        InputOutput,
        CopyFromParent,
        attribute_mask,
        &attributes);
    if (window == None) {
        fprintf(stderr, "XCreateWindow failed\n");
        XCloseDisplay(display);
        destroy_virtual_input(&wayland);
        return 2;
    }

    XClassHint class_hint = {
        .res_name = "aqueous-xwayland-grab-test",
        .res_class = "AqueousXwaylandGrabTest",
    };
    XSetClassHint(display, window, &class_hint);
    XStoreName(display, window, override_redirect
        ? "Aqueous XWayland grab test (override)"
        : "Aqueous XWayland grab test (managed)");

    XWMHints wm_hints = {.flags = InputHint, .input = True};
    XSetWMHints(display, window, &wm_hints);

    // Match SDL's Xwayland grab declaration. Compositors that apply an X11
    // allow-list consume this root-window ClientMessage before XGrabKeyboard.
    const Atom may_grab = XInternAtom(display, "_XWAYLAND_MAY_GRAB_KEYBOARD", False);
    XEvent may_grab_message = {0};
    may_grab_message.xclient.type = ClientMessage;
    may_grab_message.xclient.window = window;
    may_grab_message.xclient.message_type = may_grab;
    may_grab_message.xclient.format = 32;
    may_grab_message.xclient.data.l[0] = 1;
    may_grab_message.xclient.data.l[1] = CurrentTime;
    XSendEvent(
        display,
        root,
        False,
        SubstructureNotifyMask | SubstructureRedirectMask,
        &may_grab_message);

    XMapRaised(display, window);
    XFlush(display);

    bool mapped = false;
    bool grabbed = false;
    const double deadline = monotonic_seconds() + 20.0;
    while (monotonic_seconds() < deadline) {
        while (XPending(display) != 0) {
            XEvent event;
            XNextEvent(display, &event);

            if (event.type == MapNotify && !mapped) {
                mapped = true;
                printf("READY mode=%s window=0x%lx\n", argv[1], window);
                fflush(stdout);
                if (!activate_x11_grabs(display, window, &wayland)) {
                    XDestroyWindow(display, window);
                    XCloseDisplay(display);
                    destroy_virtual_input(&wayland);
                    return 1;
                }
                grabbed = true;
                continue;
            }

            if (event.type == KeyPress && grabbed) {
                printf("KEY keycode=%u\n", event.xkey.keycode);
                fflush(stdout);
                XUngrabKeyboard(display, CurrentTime);
                XUngrabPointer(display, CurrentTime);
                XSync(display, False);
                flush_line("RELEASED");
                XDestroyWindow(display, window);
                XCloseDisplay(display);
                destroy_virtual_input(&wayland);
                return 0;
            }
        }

        fd_set read_fds;
        FD_ZERO(&read_fds);
        FD_SET(ConnectionNumber(display), &read_fds);
        struct timeval timeout = {.tv_usec = 50000};
        const int result = select(ConnectionNumber(display) + 1, &read_fds, NULL, NULL, &timeout);
        if (result < 0 && errno != EINTR) {
            perror("select");
            break;
        }
    }

    fprintf(stderr, "timed out waiting for keyboard input\n");
    XUngrabKeyboard(display, CurrentTime);
    XUngrabPointer(display, CurrentTime);
    XDestroyWindow(display, window);
    XCloseDisplay(display);
    destroy_virtual_input(&wayland);
    return 1;
}

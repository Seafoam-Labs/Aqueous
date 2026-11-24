// SPDX-License-Identifier: GPL-3.0-only
// Regression fixture for Seafoam-Labs/Aqueous#174: the X11 <-> Wayland clipboard
// bridge must work even when no XWayland surface holds focus. Every mode here
// deliberately avoids taking focus:
//   - the X11 owner uses an InputOnly window (never mapped/focused),
//   - the X11 reader uses an unmapped window,
//   - the Wayland side uses ext-data-control, which needs no focus at all.
//
// Modes:
//   x11-own <payload>  Own the X11 CLIPBOARD and serve TARGETS/UTF8_STRING.
//                      Prints READY, then serves until killed.
//   x11-read           Request the X11 CLIPBOARD (paste). Prints DATA=<payload>,
//                      DENIED, or TIMEOUT.
//   wl-own <payload>   Own the Wayland clipboard via ext-data-control and serve
//                      send requests. Prints READY, then serves until killed.
//   wl-read            Read the Wayland clipboard via ext-data-control. Prints
//                      DATA=<payload>, EMPTY, or TIMEOUT.
#define _GNU_SOURCE
#include <assert.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include "ext-data-control-v1-client-protocol.h"

static const char *payload = "aqueous-174";
static const char *text_mime = "text/plain;charset=utf-8";

// ---------------- X11 modes ----------------

static int x11_own(void) {
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "cannot open display\n"); return 1; }
    Atom clipboard = XInternAtom(dpy, "CLIPBOARD", False);
    Atom utf8 = XInternAtom(dpy, "UTF8_STRING", False);
    Atom targets = XInternAtom(dpy, "TARGETS", False);
    Window root = DefaultRootWindow(dpy);
    XSetWindowAttributes attrs;
    attrs.event_mask = 0;
    // InputOnly: never mapped, never becomes a focused wlr_xwayland_surface.
    Window win = XCreateWindow(dpy, root, 0, 0, 1, 1, 0, 0,
        InputOnly, CopyFromParent, CWEventMask, &attrs);
    XSetSelectionOwner(dpy, clipboard, win, CurrentTime);
    XFlush(dpy);
    if (XGetSelectionOwner(dpy, clipboard) != win) {
        fprintf(stderr, "failed to take selection ownership\n"); return 1;
    }
    printf("READY\n"); fflush(stdout);
    for (;;) {
        XEvent ev;
        XNextEvent(dpy, &ev);
        if (ev.type != SelectionRequest) continue;
        XSelectionRequestEvent *req = &ev.xselectionrequest;
        if (req->selection != clipboard) continue;
        XSelectionEvent resp;
        memset(&resp, 0, sizeof(resp));
        resp.type = SelectionNotify;
        resp.display = dpy;
        resp.requestor = req->requestor;
        resp.selection = req->selection;
        resp.target = req->target;
        resp.time = req->time;
        resp.property = req->property;
        Atom prop = req->property != None ? req->property : req->target;
        if (req->target == targets) {
            Atom list[] = { targets, utf8 };
            XChangeProperty(dpy, req->requestor, prop, XA_ATOM, 32,
                PropModeReplace, (unsigned char *)list, 2);
        } else if (req->target == utf8 || req->target == XA_STRING) {
            XChangeProperty(dpy, req->requestor, prop, req->target, 8,
                PropModeReplace, (unsigned char *)payload, strlen(payload));
        } else {
            resp.property = None;
        }
        XSendEvent(dpy, req->requestor, False, 0, (XEvent *)&resp);
        XFlush(dpy);
    }
}

static int x11_read(void) {
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "cannot open display\n"); return 1; }
    Atom clipboard = XInternAtom(dpy, "CLIPBOARD", False);
    Atom utf8 = XInternAtom(dpy, "UTF8_STRING", False);
    Atom prop = XInternAtom(dpy, "AQ_READ_PROP", False);
    Window root = DefaultRootWindow(dpy);
    XSetWindowAttributes attrs;
    attrs.event_mask = PropertyChangeMask;
    // Unmapped window: never becomes a focused wlr_xwayland_surface.
    Window win = XCreateWindow(dpy, root, 0, 0, 1, 1, 0,
        CopyFromParent, InputOutput, CopyFromParent, CWEventMask, &attrs);
    XConvertSelection(dpy, clipboard, utf8, prop, win, CurrentTime);
    XFlush(dpy);
    for (int i = 0; i < 500; i++) {
        while (XPending(dpy)) {
            XEvent ev;
            XNextEvent(dpy, &ev);
            if (ev.type == SelectionNotify && ev.xselection.requestor == win) {
                if (ev.xselection.property == None) { printf("DENIED\n"); return 2; }
                Atom actual; int fmt; unsigned long n, extra; unsigned char *data = NULL;
                if (XGetWindowProperty(dpy, win, prop, 0, 4096, True,
                        AnyPropertyType, &actual, &fmt, &n, &extra, &data) == Success && data) {
                    printf("DATA=%.*s\n", (int)n, data);
                    XFree(data);
                    return 0;
                }
                printf("DENIED\n"); return 2;
            }
        }
        usleep(10000);
    }
    printf("TIMEOUT\n"); return 3;
}

// ---------------- Wayland ext-data-control modes ----------------

static struct wl_display *display;
static struct wl_seat *seat;
static struct ext_data_control_manager_v1 *manager;
static struct ext_data_control_device_v1 *device;
static struct ext_data_control_offer_v1 *current_offer;
static char offered_text_mime[64];

static void offer_mime(void *data, struct ext_data_control_offer_v1 *o, const char *type) {
    (void)data; (void)o;
    if (!strcmp(type, "text/plain;charset=utf-8") || !strcmp(type, "text/plain")) {
        snprintf(offered_text_mime, sizeof(offered_text_mime), "%s", type);
    }
}
static const struct ext_data_control_offer_v1_listener offer_listener = { .offer = offer_mime };

static void device_data_offer(void *data, struct ext_data_control_device_v1 *d,
        struct ext_data_control_offer_v1 *o) {
    (void)data; (void)d;
    offered_text_mime[0] = '\0';
    ext_data_control_offer_v1_add_listener(o, &offer_listener, NULL);
}
static void device_selection(void *data, struct ext_data_control_device_v1 *d,
        struct ext_data_control_offer_v1 *o) {
    (void)data; (void)d;
    if (current_offer) ext_data_control_offer_v1_destroy(current_offer);
    current_offer = o;
}
static void device_finished(void *data, struct ext_data_control_device_v1 *d) {
    (void)data; (void)d;
}
static void device_primary(void *data, struct ext_data_control_device_v1 *d,
        struct ext_data_control_offer_v1 *o) {
    (void)data; (void)d;
    if (o) ext_data_control_offer_v1_destroy(o);
}
static const struct ext_data_control_device_v1_listener device_listener = {
    .data_offer = device_data_offer,
    .selection = device_selection,
    .finished = device_finished,
    .primary_selection = device_primary,
};

static void source_send(void *data, struct ext_data_control_source_v1 *s,
        const char *type, int32_t fd) {
    (void)data; (void)s; (void)type;
    ssize_t len = (ssize_t)strlen(payload);
    ssize_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, payload + off, (size_t)(len - off));
        if (n <= 0) break;
        off += n;
    }
    close(fd);
}
static void source_cancelled(void *data, struct ext_data_control_source_v1 *s) {
    (void)data; (void)s;
}
static const struct ext_data_control_source_v1_listener source_listener = {
    .send = source_send,
    .cancelled = source_cancelled,
};

static void registry_global(void *data, struct wl_registry *r, uint32_t name,
        const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, "wl_seat") && !seat) {
        seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
    } else if (!strcmp(interface, "ext_data_control_manager_v1")) {
        manager = wl_registry_bind(r, name, &ext_data_control_manager_v1_interface, 1);
    }
}
static void registry_removed(void *data, struct wl_registry *r, uint32_t name) {
    (void)data; (void)r; (void)name;
}
static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_removed,
};

static void wl_connect(void) {
    display = wl_display_connect(NULL);
    assert(display);
    wl_registry_add_listener(wl_display_get_registry(display), &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0);
    assert(seat && manager);
    device = ext_data_control_manager_v1_get_data_device(manager, seat);
    ext_data_control_device_v1_add_listener(device, &device_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0);
}

static int wl_own(void) {
    wl_connect();
    struct ext_data_control_source_v1 *source =
        ext_data_control_manager_v1_create_data_source(manager);
    ext_data_control_source_v1_add_listener(source, &source_listener, NULL);
    ext_data_control_source_v1_offer(source, text_mime);
    ext_data_control_device_v1_set_selection(device, source);
    assert(wl_display_flush(display) >= 0);
    printf("READY\n"); fflush(stdout);
    // Serve send requests until killed.
    for (;;) {
        while (wl_display_prepare_read(display) != 0) {
            assert(wl_display_dispatch_pending(display) >= 0);
        }
        assert(wl_display_flush(display) >= 0);
        struct pollfd pfd = { wl_display_get_fd(display), POLLIN, 0 };
        if (poll(&pfd, 1, -1) < 0) break;
        if (pfd.revents & (POLLIN | POLLHUP | POLLERR)) {
            assert(wl_display_read_events(display) >= 0);
        } else {
            wl_display_cancel_read(display);
        }
        assert(wl_display_dispatch_pending(display) >= 0);
    }
    return 0;
}

static int wl_read(void) {
    wl_connect();
    // Wait for the bridge to publish a selection (it is asynchronous).
    for (int i = 0; i < 500 && !current_offer; i++) {
        assert(wl_display_roundtrip(display) >= 0);
        usleep(10000);
    }
    if (!current_offer || !offered_text_mime[0]) { printf("EMPTY\n"); return 2; }
    int fds[2];
    assert(pipe(fds) == 0);
    ext_data_control_offer_v1_receive(current_offer, offered_text_mime, fds[1]);
    close(fds[1]);
    assert(wl_display_flush(display) >= 0);
    char buf[4096];
    size_t total = 0;
    struct pollfd pfd = { fds[0], POLLIN, 0 };
    while (total < sizeof(buf) - 1 && poll(&pfd, 1, 5000) > 0) {
        ssize_t n = read(fds[0], buf + total, sizeof(buf) - 1 - total);
        if (n <= 0) break;
        total += (size_t)n;
    }
    close(fds[0]);
    buf[total] = '\0';
    if (total == 0) { printf("EMPTY\n"); return 2; }
    printf("DATA=%s\n", buf);
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc < 2) { fprintf(stderr, "usage: %s <mode> [payload]\n", argv[0]); return 1; }
    if (argc >= 3) payload = argv[2];
    const char *mode = argv[1];
    if (!strcmp(mode, "x11-own")) return x11_own();
    if (!strcmp(mode, "x11-read")) return x11_read();
    if (!strcmp(mode, "wl-own")) return wl_own();
    if (!strcmp(mode, "wl-read")) return wl_read();
    fprintf(stderr, "unknown mode %s\n", mode);
    return 1;
}
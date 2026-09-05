// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <assert.h>
int main(void) {
    Display *display = XOpenDisplay(NULL);
    assert(display);
    Window window = XCreateSimpleWindow(display, DefaultRootWindow(display), 0, 0, 400, 300, 0, 0, 0x287858);
    XClassHint hint = { .res_name = "aq-shell-x11", .res_class = "aq-shell-x11" };
    XSetClassHint(display, window, &hint);
    XStoreName(display, window, "same title");
    Atom close = XInternAtom(display, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(display, window, &close, 1);
    XMapWindow(display, window);
    XFlush(display);
    for (;;) {
        XEvent event;
        XNextEvent(display, &event);
        if (event.type == ClientMessage && (Atom)event.xclient.data.l[0] == close) break;
    }
    XDestroyWindow(display, window);
    XCloseDisplay(display);
    return 0;
}

// SPDX-License-Identifier: GPL-3.0-only
#include <assert.h>
#include <stdio.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    Display *display = XOpenDisplay(NULL);
    assert(display);
    Window window = XCreateSimpleWindow(display, DefaultRootWindow(display), 0, 0, 300, 200, 0, 0, 0);
    XStoreName(display, window, "Aqueous activity Xwayland fixture");
    XClassHint hint = {.res_name = "aqueous-activity-x11", .res_class = "aqueous-activity-x11"};
    XSetClassHint(display, window, &hint);
    XWMHints hints = {.flags = InputHint, .input = True};
    XSetWMHints(display, window, &hints);
    XSelectInput(display, window, KeyPressMask | KeyReleaseMask | StructureNotifyMask | FocusChangeMask);
    XMapWindow(display, window);
    XFlush(display);
    for (;;) {
        XEvent event;
        XNextEvent(display, &event);
        if (event.type == FocusIn) puts("{\"event\":\"focused\"}");
        if (event.type == MapNotify) puts("{\"event\":\"mapped\"}");
        if (event.type == KeyPress || event.type == KeyRelease) puts("{\"event\":\"key-delivered\"}");
    }
}

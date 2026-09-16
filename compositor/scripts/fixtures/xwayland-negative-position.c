// SPDX-License-Identifier: GPL-3.0-only
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <assert.h>
#include <stdio.h>

int main(void) {
    Display *display = XOpenDisplay(NULL);
    assert(display);
    setvbuf(stdout, NULL, _IOLBF, 0);
    Window root = DefaultRootWindow(display);
    Window window = XCreateSimpleWindow(display, root, 0, 0, 400, 300, 0, 0, 0x287858);
    XClassHint hint = { .res_name = "negative-position", .res_class = "negative-position" };
    XSetClassHint(display, window, &hint);
    XStoreName(display, window, "negative-position");
    XSelectInput(display, window, StructureNotifyMask | ButtonPressMask);
    XMapWindow(display, window);
    XFlush(display);
    Window popup = None;
    for (;;) {
        XEvent event;
        XNextEvent(display, &event);
        if (event.type == ConfigureNotify && event.xconfigure.window == window) {
            printf("geometry %d %d %d %d\n", event.xconfigure.x, event.xconfigure.y,
                   event.xconfigure.width, event.xconfigure.height);
        }
        if (event.type != ButtonPress) continue;
        if (event.xbutton.window == popup) {
            puts("popup-click");
            XDestroyWindow(display, popup);
            popup = None;
        } else {
            printf("click %d %d root %d %d\n", event.xbutton.x, event.xbutton.y,
                   event.xbutton.x_root, event.xbutton.y_root);
            if (event.xbutton.button == Button3) {
                XSetWindowAttributes attributes = {
                    .override_redirect = True,
                    .background_pixel = 0x785828,
                    .event_mask = ButtonPressMask,
                };
                popup = XCreateWindow(display, root, event.xbutton.x_root + 10,
                    event.xbutton.y_root + 10, 100, 100, 0, CopyFromParent, InputOutput,
                    CopyFromParent, CWOverrideRedirect | CWBackPixel | CWEventMask, &attributes);
                XSetTransientForHint(display, popup, window);
                XMapRaised(display, popup);
                puts("popup-mapped");
            }
        }
        XFlush(display);
    }
}

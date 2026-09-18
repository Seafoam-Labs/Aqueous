// SPDX-License-Identifier: GPL-3.0-only
// Interactive fixture: commands on stdin, acknowledgements on stdout.
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static void type(Display *d, Window w, const char *name) {
    Atom property = XInternAtom(d, "_NET_WM_WINDOW_TYPE", False);
    Atom values[] = {XInternAtom(d, name, False), XInternAtom(d, "_NET_WM_WINDOW_TYPE_NORMAL", False)};
    XChangeProperty(d, w, property, XA_ATOM, 32, PropModeReplace, (unsigned char *)values, 2);
}
int main(void) {
    Display *d = XOpenDisplay(NULL);
    assert(d);
    Window root = DefaultRootWindow(d);
    Window owner = XCreateSimpleWindow(d, root, 10, 10, 400, 300, 0, 0, 0x287858);
    XClassHint hint = {.res_name = "aq-notification-test", .res_class = "aq-notification-test"};
    XSetClassHint(d, owner, &hint);
    XStoreName(d, owner, "owner");
    XMapWindow(d, owner);
    XSetWindowAttributes attributes = {.override_redirect = True, .background_pixel = 0xffffff};
    Window popup = XCreateWindow(d, root, 80, 90, 160, 80, 0, CopyFromParent, InputOutput,
                                CopyFromParent, CWOverrideRedirect | CWBackPixel, &attributes);
    XSetClassHint(d, popup, &hint);
    XStoreName(d, popup, "notification");
    XSetTransientForHint(d, popup, owner);
    type(d, popup, "_NET_WM_WINDOW_TYPE_NOTIFICATION");
    XWMHints hints = {.flags = InputHint, .input = False};
    XSetWMHints(d, popup, &hints);
    XMapWindow(d, popup);
    XSync(d, False);
    puts("ready"); fflush(stdout);
    char line[512];
    while (fgets(line, sizeof(line), stdin)) {
        line[strcspn(line, "\n")] = 0;
        if (!strcmp(line, "quit")) break;
        if (!strcmp(line, "unmap")) XUnmapWindow(d, popup);
        else if (!strcmp(line, "map")) XMapWindow(d, popup);
        else if (!strcmp(line, "managed") || !strcmp(line, "unmanaged")) {
            XUnmapWindow(d, popup);
            XSync(d, False);
            attributes.override_redirect = !strcmp(line, "unmanaged");
            XChangeWindowAttributes(d, popup, CWOverrideRedirect, &attributes);
            XMapWindow(d, popup);
        } else if (!strncmp(line, "title ", 6)) XStoreName(d, popup, line + 6);
        else if (!strncmp(line, "type ", 5)) type(d, popup, line + 5);
        else if (!strncmp(line, "move ", 5)) {
            int x, y; assert(sscanf(line + 5, "%d %d", &x, &y) == 2);
            XMoveWindow(d, popup, x, y);
        } else if (!strncmp(line, "resize ", 7)) {
            unsigned int width, height; assert(sscanf(line + 7, "%u %u", &width, &height) == 2);
            XResizeWindow(d, popup, width, height);
        } else if (!strcmp(line, "grab")) {
            XGrabKeyboard(d, popup, False, GrabModeAsync, GrabModeAsync, CurrentTime);
        } else if (!strcmp(line, "ungrab")) XUngrabKeyboard(d, CurrentTime);
        else if (!strcmp(line, "geometry")) {
            XWindowAttributes a; XGetWindowAttributes(d, popup, &a);
            printf("%d %d %d %d %d\n", a.x, a.y, a.width, a.height, a.override_redirect);
            fflush(stdout); continue;
        } else if (!strcmp(line, "destroy-owner")) XDestroyWindow(d, owner);
        else abort();
        XSync(d, False);
        puts("ok"); fflush(stdout);
    }
    XCloseDisplay(d);
    return 0;
}

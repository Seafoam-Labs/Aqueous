// SPDX-License-Identifier: GPL-3.0-only
#include <X11/Xlib.h>
#include <X11/Xresource.h>
#include <stdio.h>
#include <stdlib.h>
int main(void) {
    Display *d = XOpenDisplay(NULL);
    if (!d) return 1;
    XrmInitialize();
    const char *text = XResourceManagerString(d);
    XrmDatabase db = XrmGetStringDatabase(text ? text : "");
    XrmValue value = {0}; char *type;
    double dpi = XrmGetResource(db, "Xft.dpi", "Xft.Dpi", &type, &value) ? atof(value.addr) : 0;
    printf("{\"dpi\":%.8f,\"width\":%d,\"height\":%d}\n", dpi, DisplayWidth(d, DefaultScreen(d)), DisplayHeight(d, DefaultScreen(d)));
    XrmDestroyDatabase(db); XCloseDisplay(d);
}

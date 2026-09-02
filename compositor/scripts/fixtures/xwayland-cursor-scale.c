// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#define _POSIX_C_SOURCE 200809L

#include <X11/Xcursor/Xcursor.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

enum { cursor_size = 24 };

int main(void) {
	Display *display = NULL;
	for (int attempt = 0; attempt < 200 && display == NULL; ++attempt) {
		display = XOpenDisplay(NULL);
		if (display == NULL) {
			const struct timespec delay = { .tv_nsec = 50000000 };
			nanosleep(&delay, NULL);
		}
	}
	if (display == NULL) {
		fprintf(stderr, "unable to connect to X display\n");
		return 1;
	}
	const int screen = DefaultScreen(display);
	Window root = RootWindow(display, screen);
	Window window = XCreateSimpleWindow(display, root, 0, 0, 640, 480, 0,
		BlackPixel(display, screen), BlackPixel(display, screen));
	XStoreName(display, window, "Aqueous XWayland cursor scale probe");
	XClassHint class_hint = {
		.res_name = "aqueous-xwayland-cursor-scale",
		.res_class = "AqueousXwaylandCursorScale",
	};
	XSetClassHint(display, window, &class_hint);

	XcursorImage *image = XcursorImageCreate(cursor_size, cursor_size);
	if (image == NULL) return 1;
	image->xhot = 0;
	image->yhot = 0;
	for (int i = 0; i < cursor_size * cursor_size; ++i) {
		image->pixels[i] = 0xffffffffu;
	}
	Cursor cursor = XcursorImageLoadCursor(display, image);
	XcursorImageDestroy(image);
	if (cursor == None) return 1;
	XDefineCursor(display, window, cursor);
	XSelectInput(display, window, ExposureMask | StructureNotifyMask);
	XMapWindow(display, window);
	XFlush(display);
	printf("READY cursor=%dx%d\n", cursor_size, cursor_size);
	fflush(stdout);

	for (;;) {
		XEvent event;
		XNextEvent(display, &event);
		if (event.type == DestroyNotify) break;
	}
	XFreeCursor(display, cursor);
	XCloseDisplay(display);
	return 0;
}

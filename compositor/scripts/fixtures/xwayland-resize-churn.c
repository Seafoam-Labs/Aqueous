/* SPDX-License-Identifier: GPL-3.0-only
 *
 * XWayland resize-churn client for scripts/probe-xwayland-resize-churn.py.
 *
 * Modes:
 *   idle    map a managed top-level and never touch its geometry
 *   commit  cycle between two physical sizes every <interval> ms, adopting
 *           whatever the WM actually configures, like a client that resizes
 *           its swapchain to the window
 *   force   never adopt the WM's geometry: like a game in forced window mode,
 *           re-assert one of two own resolutions whenever the WM overrides a
 *           request, bounded by FORCE_BACKOFF_MS
 *
 * stdout: one CSV line per second
 *   t_ms,configures,size_changes,moves,requests,wm_overrides,pixmaps,rss_kb
 * and a final SUMMARY,<mode> line with the same totals.
 */
#define _POSIX_C_SOURCE 200809L
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { IDLE, COMMIT, FORCE };
enum { SETTLE_MS = 1500, REPORT_MS = 1000, FORCE_BACKOFF_MS = 2 };

static long nowMs(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static long rssKb(void) {
    FILE *file = fopen("/proc/self/status", "r");
    if (!file) return 0;
    char line[128];
    long kb = 0;
    while (fgets(line, sizeof(line), file))
        if (!strncmp(line, "VmRSS:", 6)) { sscanf(line + 6, "%ld", &kb); break; }
    fclose(file);
    return kb;
}

/* Allocate and free one drawable per configure cycle, mimicking a client
 * that rebuilds backing storage on every WM-imposed resize. The working set
 * stays bounded, so an honest client keeps a flat RSS at high event rates. */
static void cyclePixmap(Display *d, Window root, int depth, unsigned w, unsigned h) {
    if (w < 1 || h < 1 || w > 4096 || h > 4096) return;
    Pixmap pixmap = XCreatePixmap(d, root, w, h, depth);
    GC gc = XCreateGC(d, pixmap, 0, NULL);
    XFillRectangle(d, pixmap, gc, 0, 0, w, h);
    XFreeGC(d, gc);
    XFreePixmap(d, pixmap);
}

int main(int argc, char **argv) {
    if (argc != 8) {
        fprintf(stderr, "usage: %s idle|commit|force <seconds> <resize-interval-ms>"
                        " <w1> <h1> <w2> <h2>\n", argv[0]);
        return 2;
    }
    int mode = !strcmp(argv[1], "idle") ? IDLE
             : !strcmp(argv[1], "commit") ? COMMIT
             : !strcmp(argv[1], "force") ? FORCE : -1;
    if (mode < 0) return 2;
    long seconds = atol(argv[2]), interval = atol(argv[3]);
    unsigned sizes[2][2] = {
        {(unsigned)atoi(argv[4]), (unsigned)atoi(argv[5])},
        {(unsigned)atoi(argv[6]), (unsigned)atoi(argv[7])},
    };

    Display *d = XOpenDisplay(NULL);
    if (!d) { fprintf(stderr, "cannot open display\n"); return 77; }
    Window root = DefaultRootWindow(d);
    int depth = DefaultDepth(d, DefaultScreen(d));

    XSetWindowAttributes attrs = {.event_mask = StructureNotifyMask, .background_pixel = 0x204040};
    Window window = XCreateWindow(d, root, 64, 64, 320, 240, 0, depth, InputOutput,
                                  DefaultVisual(d, DefaultScreen(d)),
                                  CWEventMask | CWBackPixel, &attrs);
    XClassHint class_hint = {.res_name = (char *)"aq-resize-churn-probe",
                             .res_class = (char *)"aq-resize-churn-probe"};
    XSetClassHint(d, window, &class_hint);
    XStoreName(d, window, "Aqueous resize churn probe");
    Atom wm_delete = XInternAtom(d, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(d, window, &wm_delete, 1);
    XMapWindow(d, window);

    long start = nowMs(), next_resize = start + SETTLE_MS, next_report = start + REPORT_MS;
    unsigned cur_w = 320, cur_h = 240, want = 0;
    long configures = 0, size_changes = 0, moves = 0, requests = 0, overrides = 0, pixmaps = 0;
    int running = 1;
    while (running) {
        while (XPending(d)) {
            XEvent event;
            XNextEvent(d, &event);
            if (event.type == ConfigureNotify) {
                configures++;
                unsigned w = (unsigned)event.xconfigure.width, h = (unsigned)event.xconfigure.height;
                if (w != cur_w || h != cur_h) {
                    size_changes++;
                    cur_w = w; cur_h = h;
                    cyclePixmap(d, root, depth, w, h);
                    pixmaps++;
                    if (mode == FORCE && (w != sizes[want][0] || h != sizes[want][1]))
                        overrides++;
                    if (mode == FORCE && nowMs() >= next_resize) {
                        XResizeWindow(d, window, sizes[want][0], sizes[want][1]);
                        XFlush(d);
                        requests++;
                        next_resize = nowMs() + FORCE_BACKOFF_MS;
                    }
                } else {
                    moves++;
                }
            } else if (event.type == ClientMessage) {
                running = 0;
            }
        }
        long now = nowMs();
        if (running && now - start >= seconds * 1000L) running = 0;
        if (running && mode == COMMIT && now >= next_resize) {
            XResizeWindow(d, window, sizes[want][0], sizes[want][1]);
            XFlush(d);
            requests++;
            want ^= 1;
            next_resize = now + interval;
        }
        if (running && mode == FORCE && now >= next_resize &&
            (cur_w != sizes[want][0] || cur_h != sizes[want][1])) {
            XResizeWindow(d, window, sizes[want][0], sizes[want][1]);
            XFlush(d);
            requests++;
            next_resize = now + FORCE_BACKOFF_MS;
        }
        if (running && now >= next_report) {
            printf("%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld\n", now - start,
                   configures, size_changes, moves, requests, overrides, pixmaps, rssKb());
            fflush(stdout);
            next_report += REPORT_MS;
        }
        if (running) {
            struct pollfd pfd = {.fd = ConnectionNumber(d), .events = POLLIN};
            poll(&pfd, 1, 4);
        }
    }
    printf("SUMMARY,%s,%ld,%ld,%ld,%ld,%ld,%ld,%ld\n", argv[1], configures, size_changes,
           moves, requests, overrides, pixmaps, rssKb());
    fflush(stdout);
    XCloseDisplay(d);
    return 0;
}

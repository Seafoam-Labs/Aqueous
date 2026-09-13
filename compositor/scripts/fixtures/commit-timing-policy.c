// SPDX-License-Identifier: GPL-3.0-only
#define _GNU_SOURCE
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include <wayland-client.h>
#include "commit-timing-v1-client-protocol.h"
#include "security-context-client-protocol.h"
static struct wl_compositor *compositor;
static struct wp_commit_timing_manager_v1 *timing;
static struct wp_security_context_manager_v1 *security;
static void global(void *data, struct wl_registry *registry, uint32_t id, const char *name, uint32_t version) {
    (void)data;
    if (!strcmp(name, "wl_compositor")) compositor = wl_registry_bind(registry, id, &wl_compositor_interface, 4);
    if (!strcmp(name, "wp_commit_timing_manager_v1")) {
        assert(version == 1);
        timing = wl_registry_bind(registry, id, &wp_commit_timing_manager_v1_interface, 1);
    }
    if (!strcmp(name, "wp_security_context_manager_v1")) security = wl_registry_bind(registry, id, &wp_security_context_manager_v1_interface, 1);
}
static void removed(void *d, struct wl_registry *r, uint32_t id) { (void)d; (void)r; (void)id; }
static const struct wl_registry_listener listener = {global, removed};
int main(int argc, char **argv) {
    assert(argc == 2);
    struct wl_display *display = wl_display_connect(NULL); assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &listener, NULL);
    assert(wl_display_roundtrip(display) >= 0);
    assert(compositor && timing);
    bool child = !strcmp(argv[1], "child");
    if (child) assert(!security);
    struct wl_surface *surface = wl_compositor_create_surface(compositor);
    struct wp_commit_timer_v1 *timer = wp_commit_timing_manager_v1_get_timer(timing, surface);
    wp_commit_timing_manager_v1_destroy(timing);
    wp_commit_timer_v1_set_timestamp(timer, 0, 0, 0);
    wp_commit_timer_v1_destroy(timer);
    wl_surface_commit(surface);
    assert(wl_display_roundtrip(display) >= 0);
    wl_surface_destroy(surface);
    if (!child && !strcmp(argv[1], "sandbox")) {
        assert(security);
        int sock = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0), pipefds[2];
        assert(sock >= 0 && pipe(pipefds) == 0);
        struct sockaddr_un addr = {.sun_family = AF_UNIX};
        int n = snprintf(addr.sun_path, sizeof(addr.sun_path), "%s/timing-sandbox", getenv("XDG_RUNTIME_DIR"));
        assert(n > 0 && (size_t)n < sizeof(addr.sun_path));
        assert(bind(sock, (struct sockaddr *)&addr, sizeof(addr)) == 0 && listen(sock, 8) == 0);
        struct wp_security_context_v1 *context = wp_security_context_manager_v1_create_listener(security, sock, pipefds[0]);
        wp_security_context_v1_set_sandbox_engine(context, "test");
        wp_security_context_v1_set_app_id(context, "aqueous.commit-timing-test");
        wp_security_context_v1_commit(context); wp_security_context_v1_destroy(context);
        close(sock); close(pipefds[0]);
        assert(wl_display_roundtrip(display) >= 0);
        pid_t pid = fork(); assert(pid >= 0);
        if (!pid) {
            setenv("WAYLAND_DISPLAY", addr.sun_path, 1);
            execl(argv[0], argv[0], "child", NULL);
            _exit(127);
        }
        int status; assert(waitpid(pid, &status, 0) == pid);
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
        close(pipefds[1]); unlink(addr.sun_path);
    }
    wl_registry_destroy(registry); wl_compositor_destroy(compositor);
    if (security) wp_security_context_manager_v1_destroy(security);
    wl_display_disconnect(display);
    printf("PASS commit timing registry/lifetime %s\n", argv[1]);
    return 0;
}

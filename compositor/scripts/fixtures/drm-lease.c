// SPDX-License-Identifier: GPL-3.0-only
#define _GNU_SOURCE
#include <assert.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <wayland-client.h>
#include "drm-lease-client-protocol.h"
#include "security-context-client-protocol.h"

#define MAX_DEVICES 32
#define MAX_CONNECTORS 256
static struct wl_display *display;
static struct wp_security_context_manager_v1 *security;
struct device { struct wp_drm_lease_device_v1 *proxy; uint32_t global; int fd; bool done, gone; char path[256]; };
struct connector { struct wp_drm_lease_connector_v1 *proxy; struct device *device; uint32_t id; bool done, withdrawn; char name[128]; };
static struct device devices[MAX_DEVICES];
static struct connector connectors[MAX_CONNECTORS];
static size_t device_count, connector_count;
static unsigned lease_count, finished_count;
static struct wp_drm_lease_v1 *lease;
static int lease_fd = -1;
static const char *selected[16], *selected_device;
static size_t selected_count;

static void json_string(const char *s) {
    putchar('"');
    for (; *s; s++) {
        unsigned char ch = (unsigned char)*s;
        if (ch == '"' || ch == '\\') { putchar('\\'); putchar(ch); }
        else if (ch < 32) printf("\\u%04x", ch);
        else putchar(ch);
    }
    putchar('"');
}
static void connector_name(void *data, struct wp_drm_lease_connector_v1 *proxy, const char *name) {
    struct connector *conn = data; snprintf(conn->name, sizeof(conn->name), "%s", name);
}
static void connector_description(void *data, struct wp_drm_lease_connector_v1 *proxy, const char *description) {}
static void connector_id(void *data, struct wp_drm_lease_connector_v1 *proxy, uint32_t id) { ((struct connector *)data)->id = id; }
static void connector_done(void *data, struct wp_drm_lease_connector_v1 *proxy) {
    struct connector *conn = data; conn->done = true;
    printf("{\"event\":\"connector\",\"device\":%u,\"id\":%u,\"name\":", conn->device->global, conn->id);
    json_string(conn->name); puts("}");
}
static void connector_withdrawn(void *data, struct wp_drm_lease_connector_v1 *proxy) {
    struct connector *conn = data; conn->withdrawn = true;
    printf("{\"event\":\"withdrawn\",\"device\":%u,\"id\":%u}\n", conn->device->global, conn->id);
    wp_drm_lease_connector_v1_destroy(proxy); conn->proxy = NULL;
}
static const struct wp_drm_lease_connector_v1_listener connector_listener = {
    .name = connector_name, .description = connector_description, .connector_id = connector_id,
    .done = connector_done, .withdrawn = connector_withdrawn,
};
static void device_fd(void *data, struct wp_drm_lease_device_v1 *proxy, int fd) {
    struct device *device = data; assert(device->fd == -1); device->fd = fd;
    assert(drmIsMaster(fd) == 0);
    char link[64]; snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
    ssize_t n = readlink(link, device->path, sizeof(device->path) - 1); assert(n > 0); device->path[n] = 0;
    printf("{\"event\":\"device\",\"global\":%u,\"path\":", device->global); json_string(device->path); puts("}");
}
static void device_connector(void *data, struct wp_drm_lease_device_v1 *proxy, struct wp_drm_lease_connector_v1 *obj) {
    struct device *device = data; assert(device->fd >= 0);
    assert(connector_count < MAX_CONNECTORS);
    struct connector *conn = &connectors[connector_count++];
    *conn = (struct connector){.proxy = obj, .device = device};
    wp_drm_lease_connector_v1_add_listener(obj, &connector_listener, conn);
}
static void device_done(void *data, struct wp_drm_lease_device_v1 *proxy) {
    struct device *device = data; assert(device->fd >= 0); device->done = true;
    printf("{\"event\":\"device_done\",\"global\":%u}\n", device->global);
}
static void device_released(void *data, struct wp_drm_lease_device_v1 *proxy) {
    struct device *device = data; wp_drm_lease_device_v1_destroy(proxy); device->proxy = NULL;
}
static const struct wp_drm_lease_device_v1_listener device_listener = {
    .drm_fd = device_fd, .connector = device_connector, .done = device_done, .released = device_released,
};
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    if (strcmp(interface, "wp_drm_lease_device_v1") == 0) {
        assert(version == 1 && device_count < MAX_DEVICES);
        struct device *device = &devices[device_count++];
        *device = (struct device){.global = name, .fd = -1};
        device->proxy = wl_registry_bind(registry, name, &wp_drm_lease_device_v1_interface, 1);
        wp_drm_lease_device_v1_add_listener(device->proxy, &device_listener, device);
    } else if (strcmp(interface, "wp_security_context_manager_v1") == 0) {
        security = wl_registry_bind(registry, name, &wp_security_context_manager_v1_interface, 1);
    }
}
static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    for (size_t i = 0; i < device_count; i++) if (devices[i].global == name) {
        devices[i].gone = true;
        if (devices[i].proxy) wp_drm_lease_device_v1_release(devices[i].proxy);
    }
}
static const struct wl_registry_listener registry_listener = {.global = global, .global_remove = global_remove};
static void lease_received(void *data, struct wp_drm_lease_v1 *proxy, int fd) {
    assert(lease_fd < 0 && finished_count == 0 && lease_count++ == 0);
    lease_fd = fd;
    drmModeObjectListPtr objects = drmModeGetLease(fd); assert(objects && objects->count);
    // The actual kernel lease must contain every explicitly selected connector.
    for (size_t i = 0; i < selected_count; i++) {
        uint32_t id = ((uint32_t *)data)[i]; bool found = false;
        for (uint32_t j = 0; j < objects->count; j++) if (objects->objects[j] == id) found = true;
        assert(found);
    }
    printf("{\"event\":\"lease_fd\",\"objects\":%u}\n", objects->count);
    drmFree(objects);
}
static void lease_finished(void *data, struct wp_drm_lease_v1 *proxy) {
    assert(finished_count++ == 0);
    if (lease_fd >= 0) { close(lease_fd); lease_fd = -1; }
    puts("{\"event\":\"finished\"}");
}
static const struct wp_drm_lease_v1_listener lease_listener = {.lease_fd = lease_received, .finished = lease_finished};
static uint32_t selected_ids[16];
static void request_lease(void) {
    assert(lease == NULL && selected_count > 0);
    struct connector *chosen[16] = {0}; struct device *device = NULL;
    for (size_t i = 0; i < selected_count; i++) {
        for (size_t j = 0; j < connector_count; j++) {
            struct connector *conn = &connectors[j];
            if (!conn->proxy || conn->withdrawn || !conn->done || conn->device->gone || strcmp(conn->name, selected[i])) continue;
            if (selected_device && strcmp(conn->device->path, selected_device)) continue;
            assert(chosen[i] == NULL); // Ambiguous names require --device.
            chosen[i] = conn;
        }
        assert(chosen[i]);
        if (device) assert(device == chosen[i]->device);
        device = chosen[i]->device;
        selected_ids[i] = chosen[i]->id;
    }
    lease_count = finished_count = 0;
    struct wp_drm_lease_request_v1 *request = wp_drm_lease_device_v1_create_lease_request(device->proxy);
    for (size_t i = 0; i < selected_count; i++) wp_drm_lease_request_v1_request_connector(request, chosen[i]->proxy);
    lease = wp_drm_lease_request_v1_submit(request);
    wp_drm_lease_v1_add_listener(lease, &lease_listener, selected_ids);
}
static void release_lease(void) {
    if (lease) { wp_drm_lease_v1_destroy(lease); lease = NULL; }
    if (lease_fd >= 0) { close(lease_fd); lease_fd = -1; }
}
static int sandbox_fd = -1, sandbox_lifetime = -1;
static void sandbox(void) {
    assert(security && sandbox_fd == -1);
    int lifetime[2]; assert(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, lifetime) == 0);
    sandbox_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0); assert(sandbox_fd >= 0);
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    int n = snprintf(address.sun_path, sizeof(address.sun_path), "%s/drm-lease-sandbox-%d", getenv("XDG_RUNTIME_DIR"), getpid());
    assert(n > 0 && (size_t)n < sizeof(address.sun_path));
    assert(bind(sandbox_fd, (struct sockaddr *)&address, sizeof(address)) == 0 && listen(sandbox_fd, 4) == 0);
    struct wp_security_context_v1 *context = wp_security_context_manager_v1_create_listener(security, sandbox_fd, lifetime[0]);
    wp_security_context_v1_set_sandbox_engine(context, "aqueous-test");
    wp_security_context_v1_set_app_id(context, "drm-lease-test");
    wp_security_context_v1_commit(context); wp_security_context_v1_destroy(context);
    close(lifetime[0]); sandbox_lifetime = lifetime[1];
    assert(wl_display_roundtrip(display) >= 0);
    printf("{\"event\":\"sandbox\",\"socket\":"); json_string(address.sun_path); puts("}");
}
int main(int argc, char **argv) {
    setbuf(stdout, NULL); bool absent = false;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--absent")) absent = true;
        else if (!strcmp(argv[i], "--connector")) { assert(++i < argc && selected_count < 16); selected[selected_count++] = argv[i]; }
        else if (!strcmp(argv[i], "--device")) { assert(++i < argc); selected_device = argv[i]; }
        else { fprintf(stderr, "Unknown argument: %s\n", argv[i]); return 2; }
    }
    display = wl_display_connect(NULL); assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0 && wl_display_roundtrip(display) >= 0);
    if (absent) assert(device_count == 0);
    printf("{\"event\":\"ready\",\"devices\":%zu}\n", device_count);
    char command[128];
    for (;;) {
        assert(wl_display_flush(display) >= 0);
        struct pollfd fds[] = {{wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        assert(poll(fds, 2, -1) > 0);
        if (fds[0].revents) assert(wl_display_dispatch(display) >= 0);
        if (fds[1].revents) {
            if (!fgets(command, sizeof(command), stdin) || !strcmp(command, "quit\n")) break;
            if (!strcmp(command, "lease\n")) request_lease();
            else if (!strcmp(command, "release\n")) release_lease();
            else if (!strcmp(command, "sandbox\n")) sandbox();
            else if (!strcmp(command, "crash\n")) _exit(0);
            else if (strcmp(command, "sync\n")) abort();
            assert(wl_display_roundtrip(display) >= 0);
            printf("{\"event\":\"command\",\"name\":"); command[strcspn(command, "\n")] = 0; json_string(command); puts("}");
        }
    }
    release_lease();
    for (size_t i = 0; i < connector_count; i++) if (connectors[i].proxy) wp_drm_lease_connector_v1_destroy(connectors[i].proxy);
    for (size_t i = 0; i < device_count; i++) {
        if (devices[i].proxy && !devices[i].gone) wp_drm_lease_device_v1_release(devices[i].proxy);
        if (devices[i].fd >= 0) close(devices[i].fd);
    }
    assert(wl_display_roundtrip(display) >= 0);
    if (sandbox_lifetime >= 0) close(sandbox_lifetime);
    if (sandbox_fd >= 0) close(sandbox_fd);
    if (security) wp_security_context_manager_v1_destroy(security);
    wl_registry_destroy(registry); wl_display_disconnect(display);
    return 0;
}

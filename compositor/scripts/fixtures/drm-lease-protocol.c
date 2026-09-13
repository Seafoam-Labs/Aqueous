// SPDX-License-Identifier: GPL-3.0-only
// Real wlroots request handlers and Wayland resources; DRM calls are synthetic.
#define _GNU_SOURCE
#include <assert.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/backend/drm.h>
#include <wlr/backend/multi.h>
#include <wlr/types/wlr_drm_lease_v1.h>
#include "backend/drm/drm.h"

static int allocation_countdown = -1;
static bool fail_realloc;
static void *fault_calloc(size_t count, size_t size) {
    if (allocation_countdown == 0) { allocation_countdown = -1; return NULL; }
    if (allocation_countdown > 0) allocation_countdown--;
    return calloc(count, size);
}
static void *fault_realloc(void *pointer, size_t size) {
    if (fail_realloc) { fail_realloc = false; return NULL; }
    return realloc(pointer, size);
}
#define calloc fault_calloc
#define realloc fault_realloc
#include "drm-lease-source.h"
#undef calloc
#undef realloc

static struct wlr_drm_backend drm = {0};
static bool grant_success;
static unsigned grants, finishes, lease_fds, errors, error_code;
static unsigned discovery_fds, connector_events, connector_done, device_done, withdrawn, released;
static const char *error_interface;

bool wlr_backend_is_drm(struct wlr_backend *backend) { return backend == &drm.backend; }
bool wlr_backend_is_multi(struct wlr_backend *backend) { return false; }
bool wlr_output_is_drm(struct wlr_output *output) { return output->backend == &drm.backend; }
struct wlr_drm_backend *get_drm_backend_from_backend(struct wlr_backend *backend) {
    assert(wlr_backend_is_drm(backend)); return &drm;
}
int wlr_drm_backend_get_non_master_fd(struct wlr_backend *backend) {
    return open("/dev/null", O_RDONLY | O_CLOEXEC);
}
uint32_t wlr_drm_connector_get_id(struct wlr_output *output) { return 42; }
void wlr_global_destroy_safe(struct wl_global *global) { wl_global_destroy(global); }
struct wlr_drm_lease *wlr_drm_create_lease(struct wlr_output **outputs, size_t count, int *fd) {
    grants++;
    if (!grant_success) return NULL;
    struct wlr_drm_lease *lease = calloc(1, sizeof(*lease));
    assert(lease);
    lease->backend = &drm;
    lease->lessee_id = 7;
    wl_signal_init(&lease->events.destroy);
    *fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    assert(*fd >= 0);
    for (size_t i = 0; i < count; i++) wl_signal_emit_mutable(&outputs[i]->events.destroy, outputs[i]);
    return lease;
}
void wlr_drm_lease_terminate(struct wlr_drm_lease *lease) {
    wl_signal_emit_mutable(&lease->events.destroy, NULL);
    assert(wl_list_empty(&lease->events.destroy.listener_list));
    free(lease);
}
static void protocol_log(void *data, enum wl_protocol_logger_type type,
        const struct wl_protocol_logger_message *message) {
    if (type != WL_PROTOCOL_LOGGER_EVENT) return;
    const char *interface = wl_resource_get_class(message->resource);
    const char *event = message->message->name;
    if (strcmp(interface, "wp_drm_lease_v1") == 0) {
        if (strcmp(event, "finished") == 0) finishes++;
        if (strcmp(event, "lease_fd") == 0) lease_fds++;
    } else if (strcmp(interface, "wp_drm_lease_device_v1") == 0) {
        if (strcmp(event, "drm_fd") == 0) { assert(!connector_events); discovery_fds++; }
        if (strcmp(event, "connector") == 0) { assert(discovery_fds); connector_events++; }
        if (strcmp(event, "done") == 0) { assert(connector_done == connector_events); device_done++; }
        if (strcmp(event, "released") == 0) released++;
    } else if (strcmp(interface, "wp_drm_lease_connector_v1") == 0) {
        if (strcmp(event, "done") == 0) connector_done++;
        if (strcmp(event, "withdrawn") == 0) withdrawn++;
    } else if (strcmp(interface, "wl_display") == 0 && strcmp(event, "error") == 0) {
        errors++;
        error_code = message->arguments[1].u;
        error_interface = wl_resource_get_class((struct wl_resource *)message->arguments[0].o);
    }
}
static enum { GRANT, REJECT, IGNORE, OOM } response;
static void on_request(struct wl_listener *listener, void *data) {
    struct wlr_drm_lease_request_v1 *request = data;
    if (response == REJECT) wlr_drm_lease_request_v1_reject(request);
    if (response == OOM) allocation_countdown = 0;
    if (response == GRANT || response == OOM) wlr_drm_lease_request_v1_grant(request);
}

static void run(const char *scenario) {
    grants = finishes = lease_fds = errors = error_code = 0;
    discovery_fds = connector_events = connector_done = device_done = withdrawn = released = 0;
    error_interface = NULL;
    grant_success = false;
    response = GRANT;
    struct wl_display *display = wl_display_create();
    assert(display);
    struct wl_protocol_logger *logger = wl_display_add_protocol_logger(display, protocol_log, NULL);
    int pair[2]; assert(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair) == 0);
    struct wl_client *client = wl_client_create(display, pair[0]); assert(client);
    drm.name = "synthetic DRM";
    wl_signal_init(&drm.backend.events.destroy);
    struct wlr_drm_lease_v1_manager *manager = wlr_drm_lease_v1_manager_create(display, &drm.backend);
    assert(manager);
    struct wl_listener listener = {.notify = on_request};
    wl_signal_add(&manager->events.request, &listener);
    struct wlr_drm_lease_device_v1 *device = wl_container_of(manager->devices.next, device, link);
    struct wlr_output output = {.backend = &drm.backend, .name = "TEST-VR-1", .description = "Synthetic headset", .non_desktop = true};
    wl_signal_init(&output.events.destroy);
    assert(wlr_drm_lease_v1_manager_offer_output(manager, &output));
    lease_device_bind(client, device, 1, 2);
    struct wl_resource *device_resource = wl_client_get_object(client, 2);
    assert(discovery_fds == 1 && connector_events == 1 && connector_done == 1 && device_done == 1);
    struct wlr_drm_lease_connector_v1 *connector = wl_container_of(device->connectors.next, connector, link);
    struct wl_resource *connector_resource = wl_resource_from_link(connector->resources.next);
    if (strcmp(scenario, "request-oom") == 0) allocation_countdown = 0;
    drm_lease_device_v1_handle_create_lease_request(client, device_resource, 3);
    struct wl_resource *request = wl_client_get_object(client, 3); assert(request);
    if (strcmp(scenario, "request-oom") == 0) {
        assert(errors == 1 && error_code == WL_DISPLAY_ERROR_NO_MEMORY && grants == 0);
        assert(wl_resource_get_user_data(request) == NULL);
        goto cleanup;
    }

    if (strcmp(scenario, "empty") != 0) {
        if (strcmp(scenario, "stale-before") == 0) wlr_drm_lease_v1_manager_withdraw_output(manager, &output);
        if (strcmp(scenario, "connector-oom") == 0) fail_realloc = true;
        drm_lease_request_v1_handle_request_connector(client, request, connector_resource);
    }
    if (strcmp(scenario, "connector-oom") == 0) {
        assert(errors == 1 && error_code == WL_DISPLAY_ERROR_NO_MEMORY && grants == 0);
        assert(((struct wlr_drm_lease_request_v1 *)wl_resource_get_user_data(request))->invalid);
        goto cleanup;
    }
    if (strcmp(scenario, "withdraw-pending") == 0) {
        wlr_drm_lease_v1_manager_withdraw_output(manager, &output);
    } else if (strcmp(scenario, "duplicate") == 0) {
        drm_lease_request_v1_handle_request_connector(client, request, connector_resource);
        assert(errors == 1 && error_code == WP_DRM_LEASE_REQUEST_V1_ERROR_DUPLICATE_CONNECTOR);
        assert(strcmp(error_interface, "wp_drm_lease_request_v1") == 0);
        goto cleanup;
    } else if (strcmp(scenario, "wrong-device") == 0) {
        struct wlr_drm_lease_request_v1 *req = wl_resource_get_user_data(request);
        req->device = NULL;
        drm_lease_request_v1_handle_request_connector(client, request, connector_resource);
        req->device = device;
        assert(errors == 1 && error_code == WP_DRM_LEASE_REQUEST_V1_ERROR_WRONG_DEVICE);
        goto cleanup;
    } else if (strcmp(scenario, "reject") == 0) response = REJECT;
    else if (strcmp(scenario, "ignore") == 0) response = IGNORE;
    else if (strcmp(scenario, "oom") == 0) response = OOM;
    else if (strcmp(scenario, "device-removed") == 0) {
        drm_lease_device_v1_destroy(device);
        device = NULL;
    } else if (strcmp(scenario, "grant-release") == 0 || strcmp(scenario, "grant-crash") == 0 || strcmp(scenario, "compete") == 0) {
        grant_success = true;
        // Queue a competing request before the first grant withdraws its offer.
        drm_lease_device_v1_handle_create_lease_request(client, device_resource, 4);
        drm_lease_request_v1_handle_request_connector(client, wl_client_get_object(client, 4), connector_resource);
    }
    drm_lease_request_v1_handle_submit(client, request, grant_success ? 5 : 4);
    assert(wl_client_get_object(client, 3) == NULL);
    if (strcmp(scenario, "empty") == 0) {
        assert(errors == 1 && error_code == WP_DRM_LEASE_REQUEST_V1_ERROR_EMPTY_LEASE);
        assert(strcmp(error_interface, "wp_drm_lease_request_v1") == 0);
    } else if (response == OOM) {
        assert(errors == 1 && error_code == WL_DISPLAY_ERROR_NO_MEMORY && finishes == 0 && grants == 0);
    } else if (grant_success) {
        assert(grants == 1 && lease_fds == 1 && finishes == 0 && withdrawn == 1);
        drm_lease_request_v1_handle_submit(client, wl_client_get_object(client, 4), 6);
        assert(grants == 1 && finishes == 1 && wl_client_get_object(client, 4) == NULL);
        if (strcmp(scenario, "grant-crash") == 0) {
            wl_client_destroy(client); client = NULL;
        } else {
            drm_lease_v1_handle_destroy(client, wl_client_get_object(client, 5));
            assert(finishes == 2);
        }
        assert(wl_list_empty(&device->leases));
        assert(wlr_drm_lease_v1_manager_offer_output(manager, &output));
    } else {
        assert(finishes == 1 && lease_fds == 0);
        if (strcmp(scenario, "failure") == 0) assert(grants == 1);
        else assert(grants == 0);
    }
    if (device != NULL) assert(wl_list_empty(&device->requests));
    if (client != NULL && errors == 0) {
        drm_lease_device_v1_handle_release(client, device_resource);
        assert(released == 1 && wl_client_get_object(client, 2) == NULL);
    }
cleanup:
    if (client != NULL) wl_client_destroy(client);
    close(pair[1]);
    wl_list_remove(&listener.link);
    wl_protocol_logger_destroy(logger);
    wl_display_destroy(display);
    printf("PASS protocol: %s\n", scenario);
}
static unsigned fd_count(void) {
    DIR *directory = opendir("/proc/self/fd"); assert(directory);
    unsigned count = 0;
    struct dirent *entry;
    while ((entry = readdir(directory))) if (entry->d_name[0] != '.') count++;
    closedir(directory);
    return count;
}
int main(void) {
    setbuf(stdout, NULL);
    unsigned descriptors = fd_count();
    const char *scenarios[] = {"failure", "reject", "ignore", "withdraw-pending", "stale-before", "device-removed", "empty", "duplicate", "wrong-device", "oom", "request-oom", "connector-oom", "grant-release", "grant-crash", "compete"};
    for (size_t i = 0; i < sizeof(scenarios)/sizeof(scenarios[0]); i++) {
        run(scenarios[i]);
        assert(fd_count() == descriptors);
    }
    return 0;
}

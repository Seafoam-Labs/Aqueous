// SPDX-License-Identifier: GPL-3.0-only
// Native API doubles for the production Zig manager's lifecycle tests.
#include <assert.h>
#include <stdlib.h>
#include <wayland-server-core.h>
#include <wlr/backend/drm.h>
#include <wlr/types/wlr_drm_lease_v1.h>
static struct wlr_backend backends[2];
static struct wlr_drm_lease_v1_manager manager;
static struct wlr_drm_lease_device_v1 devices[2];
static bool unavailable, fail_offer;
unsigned aqueous_drm_test_offers, aqueous_drm_test_grants, aqueous_drm_test_rejects, aqueous_drm_test_revokes;
extern void aqueous_drm_test_reoffer(struct wlr_output *output);

void aqueous_drm_test_reset(bool missing, bool fail) {
    unavailable = missing; fail_offer = fail;
    aqueous_drm_test_offers = aqueous_drm_test_grants = aqueous_drm_test_rejects = aqueous_drm_test_revokes = 0;
}
bool wlr_output_is_drm(struct wlr_output *output) { return output->backend == &backends[0] || output->backend == &backends[1]; }
bool wlr_output_commit_state(struct wlr_output *output, const struct wlr_output_state *state) {
    assert((state->committed & WLR_OUTPUT_STATE_ENABLED) && !state->enabled);
    output->enabled = false;
    return true;
}
struct wlr_output *aqueous_drm_test_output(int device, bool non_desktop) {
    struct wlr_output *output = calloc(1, sizeof(*output)); assert(output);
    output->backend = device < 0 ? NULL : &backends[device];
    output->name = "TEST-VR"; output->non_desktop = non_desktop;
    wl_signal_init(&output->events.destroy);
    return output;
}
void aqueous_drm_test_destroy_output(struct wlr_output *output) {
    wl_signal_emit_mutable(&output->events.destroy, output);
    assert(wl_list_empty(&output->events.destroy.listener_list)); free(output);
}
struct wlr_drm_lease_v1_manager *wlr_drm_lease_v1_manager_create(struct wl_display *display, struct wlr_backend *backend) {
    if (unavailable) return NULL;
    wl_list_init(&manager.devices); wl_signal_init(&manager.events.request); wl_signal_init(&manager.events.destroy);
    for (int i = 0; i < 2; i++) {
        devices[i].backend = &backends[i]; devices[i].manager = &manager;
        wl_list_init(&devices[i].connectors); wl_list_init(&devices[i].leases);
        wl_list_insert(&manager.devices, &devices[i].link);
    }
    return &manager;
}
static void output_destroy(struct wl_listener *listener, void *data) {
    struct wlr_drm_lease_connector_v1 *connector = wl_container_of(listener, connector, destroy);
    wlr_drm_lease_v1_manager_withdraw_output(&manager, connector->output);
}
bool wlr_drm_lease_v1_manager_offer_output(struct wlr_drm_lease_v1_manager *m, struct wlr_output *output) {
    assert(m == &manager);
    if (fail_offer) return false;
    struct wlr_drm_lease_device_v1 *device = &devices[output->backend == &backends[0] ? 0 : 1];
    struct wlr_drm_lease_connector_v1 *conn;
    wl_list_for_each(conn, &device->connectors, link) assert(conn->output != output);
    conn = calloc(1, sizeof(*conn)); assert(conn);
    conn->output = output; conn->device = device;
    wl_list_insert(&device->connectors, &conn->link);
    conn->destroy.notify = output_destroy; wl_signal_add(&output->events.destroy, &conn->destroy);
    aqueous_drm_test_offers++;
    return true;
}
void wlr_drm_lease_v1_manager_withdraw_output(struct wlr_drm_lease_v1_manager *m, struct wlr_output *output) {
    for (int i = 0; i < 2; i++) {
        struct wlr_drm_lease_connector_v1 *conn, *tmp;
        wl_list_for_each_safe(conn, tmp, &devices[i].connectors, link) if (conn->output == output) {
            wl_list_remove(&conn->destroy.link); wl_list_remove(&conn->link); free(conn);
        }
    }
}
struct wlr_drm_lease_v1 *wlr_drm_lease_request_v1_grant(struct wlr_drm_lease_request_v1 *request) {
    struct wlr_drm_lease_v1 *lease = calloc(1, sizeof(*lease)); assert(lease);
    lease->device = request->device;
    wl_list_insert(&lease->device->leases, &lease->link);
    for (size_t i = 0; i < request->n_connectors; i++) aqueous_drm_test_destroy_output(request->connectors[i]->output);
    aqueous_drm_test_grants++;
    return lease;
}
void wlr_drm_lease_request_v1_reject(struct wlr_drm_lease_request_v1 *request) { aqueous_drm_test_rejects++; }
void wlr_drm_lease_v1_revoke(struct wlr_drm_lease_v1 *lease) {
    int device = lease->device == &devices[0] ? 0 : 1;
    wl_list_remove(&lease->link); free(lease); aqueous_drm_test_revokes++;
    // Deliberately re-enter output discovery synchronously, the hardest ordering.
    aqueous_drm_test_reoffer(aqueous_drm_test_output(device, true));
}
void aqueous_drm_test_request(int device, bool invalid) {
    struct wlr_drm_lease_connector_v1 *connectors[16]; size_t count = 0;
    struct wlr_drm_lease_connector_v1 *conn;
    wl_list_for_each(conn, &devices[device].connectors, link) { assert(count < 16); connectors[count++] = conn; }
    struct wlr_drm_lease_request_v1 request = {.device = &devices[device], .connectors = invalid ? NULL : connectors,
        .n_connectors = invalid ? 99 : count, .invalid = invalid};
    wl_signal_emit_mutable(&manager.events.request, &request);
}
void aqueous_drm_test_destroy_manager(void) {
    wl_signal_emit_mutable(&manager.events.destroy, NULL);
    assert(wl_list_empty(&manager.events.destroy.listener_list));
    assert(wl_list_empty(&manager.events.request.listener_list));
    for (int i = 0; i < 2; i++) assert(wl_list_empty(&devices[i].leases) && wl_list_empty(&devices[i].connectors));
}

// SPDX-License-Identifier: GPL-3.0-only
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#include <wlr/backend/drm.h>
#include <wlr/util/log.h>
#include "backend/drm/drm.h"
#include "backend/drm/properties.h"
#include "backend/drm/util.h"

static int revoke_errno;
static int blank_errno;
static unsigned revokes, destroyed, scans, blanks;
static bool connected = true, listed = true;
static bool creating_failure;
int drmModeCreateLease(int fd, const uint32_t *objects, int count, int flags, uint32_t *id) {
    if (creating_failure) { errno = EBUSY; return -1; }
    assert(count == 6); // Two connectors, each with a CRTC and primary plane.
    for (int i = 0; i < count; i++) for (int j = 0; j < i; j++) assert(objects[i] != objects[j]);
    *id = 7;
    return open("/dev/null", O_RDONLY | O_CLOEXEC);
}
struct wlr_drm_backend *get_drm_backend_from_backend(struct wlr_backend *backend) {
    struct wlr_drm_backend *drm = wl_container_of(backend, drm, backend); return drm;
}
static struct wlr_drm_connector *get_drm_connector_from_output(struct wlr_output *output) {
    struct wlr_drm_connector *conn = wl_container_of(output, conn, output); return conn;
}
const char *drm_connector_status_str(drmModeConnection status) { return "test"; }
static void dealloc_crtc(struct wlr_drm_connector *conn) {
    assert(!conn->output.enabled); // Never disturb an enabled desktop output.
    conn->crtc = NULL;
}
int drmModeSetCrtc(int fd, uint32_t crtc, uint32_t buffer, uint32_t x, uint32_t y,
        uint32_t *connectors, int count, drmModeModeInfoPtr mode) {
    assert(buffer == 0 && connectors == NULL && count == 0 && mode == NULL);
    assert(crtc == 13); // The desktop CRTC must never be touched.
    blanks++;
    if (blank_errno) { errno = blank_errno; return -1; }
    return 0;
}
int drmModeRevokeLease(int fd, uint32_t lessee) {
    revokes++;
    if (revoke_errno) { errno = revoke_errno; return -1; }
    return 0;
}
drmModeResPtr drmModeGetResources(int fd) {
    scans++;
    drmModeResPtr res = calloc(1, sizeof(*res)); assert(res);
    if (listed) { res->count_connectors = 1; res->connectors = malloc(sizeof(uint32_t)); assert(res->connectors); res->connectors[0] = 42; }
    return res;
}
drmModeConnectorPtr drmModeGetConnector(int fd, uint32_t id) {
    drmModeConnectorPtr conn = calloc(1, sizeof(*conn)); assert(conn);
    conn->connector_id = id; conn->connection = connected ? DRM_MODE_CONNECTED : DRM_MODE_DISCONNECTED;
    return conn;
}
drmModeLesseeListPtr drmModeListLessees(int fd) {
    drmModeLesseeListPtr list = calloc(1, sizeof(*list)); assert(list); return list;
}
static struct wlr_drm_connector *create_drm_connector(struct wlr_drm_backend *drm, const drmModeConnector *conn) { abort(); }
static bool connect_drm_connector(struct wlr_drm_connector *conn, const drmModeConnector *drm_conn) { conn->status = DRM_MODE_CONNECTED; return true; }
static void disconnect_drm_connector(struct wlr_drm_connector *conn) {
    conn->status = DRM_MODE_DISCONNECTED;
    conn->crtc = NULL;
}
bool get_drm_prop(int fd, uint32_t obj, uint32_t prop, uint64_t *value) { return false; }

#include "drm-lease-backend-functions.h"

static void lease_destroyed(struct wl_listener *listener, void *data) {
    assert(blanks == 1); // Never acknowledge revocation before blanking scanout.
    destroyed++;
    wl_list_remove(&listener->link);
}
static void run(int scenario) {
    revokes = destroyed = scans = blanks = 0; revoke_errno = blank_errno = 0; connected = listed = true;
    struct wl_event_loop *loop = wl_event_loop_create(); assert(loop);
    struct wlr_session session = {.active = true, .event_loop = loop};
    struct wlr_drm_backend drm = {.session = &session, .name = "test"};
    wl_list_init(&drm.connectors); wl_signal_init(&drm.backend.events.new_output);
    struct wlr_drm_crtc crtcs[2] = {{.id = 13}, {.id = 14}};
    drm.crtcs = crtcs; drm.num_crtcs = 2;
    struct wlr_drm_connector *conn = calloc(1, sizeof(*conn)); assert(conn);
    conn->backend = &drm; conn->id = 42; conn->status = DRM_MODE_DISCONNECTED;
    strcpy(conn->name, "TEST-VR"); wl_list_insert(&drm.connectors, &conn->link);
    struct wlr_drm_lease *lease = calloc(1, sizeof(*lease)); assert(lease);
    lease->backend = &drm; lease->lessee_id = 7;
    wl_signal_init(&lease->events.destroy);
    struct wl_listener destroy = {.notify = lease_destroyed}; wl_signal_add(&lease->events.destroy, &destroy);
    conn->lease = crtcs[0].lease = lease;
    if (scenario == 0) {
        scan_drm_connectors(&drm, NULL);
        assert(!wl_list_empty(&drm.connectors) && conn->lease == lease && destroyed == 0);
        connected = false;
        scan_drm_connectors(&drm, NULL);
        assert(revokes == 1 && destroyed == 1 && conn->lease == NULL);
    } else if (scenario == 1) {
        listed = false; // A connector disappearing revokes the entire lease.
        scan_drm_connectors(&drm, NULL);
        assert(wl_list_empty(&drm.connectors) && destroyed == 1);
    } else if (scenario == 2) {
        scan_drm_leases(&drm); // Kernel already removed the lessee.
        assert(destroyed == 1 && revokes == 0);
    } else {
        if (scenario == 3) session.active = false;
        if (scenario == 4) drm.destroying = true;
        if (scenario == 5) revoke_errno = ENOENT;
        if (scenario == 6) revoke_errno = ENODEV;
        if (scenario == 7) revoke_errno = EACCES;
        if (scenario == 8) blank_errno = EIO;
        wlr_drm_lease_terminate(lease);
        assert(destroyed == 1 && revokes == 1);
    }
    assert(crtcs[0].lease == NULL);
    if (scenario == 3 || scenario == 4) assert(drm.lease_rescan == NULL);
    else {
        assert(drm.lease_rescan != NULL);
        unsigned before = scans;
        wl_event_loop_dispatch_idle(loop);
        assert(drm.lease_rescan == NULL && scans == before + 1);
    }
    // No recursive rescan has corrupted the connector list.
    if (!wl_list_empty(&drm.connectors)) {
        conn = wl_container_of(drm.connectors.next, conn, link);
        destroy_drm_connector(conn);
    }
    wl_event_loop_destroy(loop);
}
static void allocation(int failure) {
    struct wlr_session session = {.active = true};
    struct wlr_drm_backend drm = {.session = &session, .destroying = true};
    wl_list_init(&drm.connectors);
    struct wlr_drm_plane planes[3] = {{.id = 100}, {.id = 101}, {.id = 102}};
    struct wlr_drm_crtc crtcs[3] = {
        {.id = 10, .primary = &planes[0]}, {.id = 11, .primary = &planes[1]}, {.id = 12, .primary = &planes[2]},
    };
    drm.crtcs = crtcs; drm.num_crtcs = failure == 2 ? 2 : 3;
    struct wlr_drm_connector connectors[4] = {0};
    for (int i = 0; i < 4; i++) {
        connectors[i].backend = &drm; connectors[i].id = 40 + i;
        connectors[i].output.backend = &drm.backend;
        connectors[i].status = DRM_MODE_CONNECTED; connectors[i].possible_crtcs = 7;
        wl_list_insert(drm.connectors.prev, &connectors[i].link);
    }
    struct wlr_drm_crtc *desktop_crtc = &crtcs[drm.num_crtcs - 1];
    connectors[2].crtc = desktop_crtc; connectors[2].output.enabled = true;
    struct wlr_output *outputs[] = {&connectors[0].output, &connectors[1].output};
    int fd = -1;
    creating_failure = failure == 1;
    struct wlr_drm_lease *lease = wlr_drm_create_lease(outputs, 2, &fd);
    for (int i = 0; i < 4; i++) assert(!connectors[i].lease_pending);
    assert(connectors[2].crtc == desktop_crtc && connectors[2].output.enabled);
    if (failure) {
        assert(!lease && fd == -1);
        for (int i = 0; i < 3; i++) assert(crtcs[i].lease == NULL);
        return;
    }
    assert(lease && fd >= 0); close(fd);
    assert(crtcs[0].lease == lease && crtcs[1].lease == lease && !crtcs[2].lease);
    // A newly connected desktop output cannot take either leased CRTC.
    realloc_crtcs(&drm, &connectors[3]);
    assert(connectors[3].crtc == NULL && connectors[2].crtc == &crtcs[2]);
    free(lease);
}
int main(void) {
    struct rlimit limit = {0, 0}; assert(setrlimit(RLIMIT_CORE, &limit) == 0);
    for (int i = 0; i < 7; i++) run(i);
    allocation(0);
    allocation(1);
    allocation(2);
    for (int i = 7; i < 9; i++) {
        pid_t child = fork(); assert(child >= 0);
        if (!child) { run(i); _exit(1); }
        int status; assert(waitpid(child, &status, 0) == child);
        assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
    }
    puts("PASS backend: leased connector retention, unplug/removal, kernel release, deferred rediscovery, inactive/shutdown and revocation errors");
    puts("PASS allocator: multi-connector lease, failed grant and leased CRTC exclusion preserve the desktop");
    return 0;
}

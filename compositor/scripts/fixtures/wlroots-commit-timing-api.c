// SPDX-License-Identifier: GPL-3.0-only
#define WLR_USE_UNSTABLE
#include <assert.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_commit_timing_v1.h>
_Static_assert(WLR_AQUEOUS_COMMIT_TIMING_VERSION == 1, "commit timing API required");
int main(void) {
    struct wl_display *display = wl_display_create();
    assert(display);
    struct wlr_commit_timing_manager_v1 *manager = wlr_commit_timing_manager_v1_create(display);
    assert(manager && wlr_commit_timing_manager_v1_get_global(manager));
    wl_display_destroy(display);
    return 0;
}

// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

/// Lease devices have one global per DRM backend, created before the manager
/// has stored its returned global pointer. Keep them privileged at creation.
pub fn dynamicallyBlocklistedInterface(interface_name: [*:0]const u8) bool {
    return std.mem.orderZ(u8, interface_name, "wp_drm_lease_device_v1") == .eq;
}

test "every DRM lease device is privileged without blocklisting wl_output" {
    try std.testing.expect(dynamicallyBlocklistedInterface("wp_drm_lease_device_v1"));
    try std.testing.expect(!dynamicallyBlocklistedInterface("wl_output"));
    try std.testing.expect(!dynamicallyBlocklistedInterface("wp_drm_lease_v1"));
}

/// wl_global_create() invokes the server's global filter before returning the
/// new global pointer. During renderer recovery, recognize only the
/// linux-dmabuf interface being recreated in that interval.
pub fn temporarilyAllowlistedInterface(
    creating_linux_dmabuf_global: bool,
    interface_name: [*:0]const u8,
) bool {
    return creating_linux_dmabuf_global and
        std.mem.orderZ(u8, interface_name, "zwp_linux_dmabuf_v1") == .eq;
}

test "linux-dmabuf recovery allowlists only the pending replacement global" {
    try std.testing.expect(temporarilyAllowlistedInterface(
        true,
        "zwp_linux_dmabuf_v1",
    ));
    try std.testing.expect(!temporarilyAllowlistedInterface(
        false,
        "zwp_linux_dmabuf_v1",
    ));
    try std.testing.expect(!temporarilyAllowlistedInterface(true, "wl_shm"));
}

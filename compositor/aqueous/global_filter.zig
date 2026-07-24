// SPDX-FileCopyrightText: © 2026 The Aqueous Developers
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

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

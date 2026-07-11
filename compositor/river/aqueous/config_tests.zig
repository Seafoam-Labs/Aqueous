// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

test {
    _ = @import("config/layout.zig");
    _ = @import("config/loader.zig");
    _ = @import("config/wm.zig");
    _ = @import("layout/engine.zig");
    _ = @import("rules/config.zig");
    _ = @import("state/store.zig");
}

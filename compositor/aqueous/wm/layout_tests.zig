// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

// Keep the module root above both configuration and layout implementations.
test {
    _ = @import("layout/tests.zig");
    _ = @import("layout/engine.zig");
    _ = @import("config/layout.zig");
    _ = @import("workspaces/overflow.zig");
}

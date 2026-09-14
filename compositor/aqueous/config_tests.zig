// SPDX-License-Identifier: GPL-3.0-only
// Root at aqueous/ so loader tests can use the same canonical persistence code.
test {
    _ = @import("wm/config_tests.zig");
    _ = @import("ConfigTransaction.zig");
    _ = @import("ConfigDocument.zig");
}

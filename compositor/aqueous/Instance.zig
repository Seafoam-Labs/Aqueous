// SPDX-License-Identifier: GPL-3.0-only
//! Package instance identity. Stable builds retain every existing path.
const root = @import("root");
pub const name: []const u8 = if (@hasDecl(root, "aqueous_instance_name")) root.aqueous_instance_name else "aqueous";
comptime {
    if (name.len == 0) @compileError("An Aqueous instance name is required");
    for (name) |ch| if (!((ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-'))
        @compileError("Invalid Aqueous instance name");
}

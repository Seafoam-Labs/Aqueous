//! Build identity for side-by-side desktop packages; tests default to stable.
const std = @import("std");
const root = @import("root");
pub const name = if (@hasDecl(root, "aqueous_instance_name")) root.aqueous_instance_name else "aqueous";
pub const suffix = if (std.mem.eql(u8, name, "aqueous")) "" else if (std.mem.eql(u8, name, "aqueous-git")) "-git" else if (std.mem.eql(u8, name, "aqueous-intel-git")) "-intel-git" else @compileError("Unsupported portal picker instance");

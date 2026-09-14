//! Build identity for side-by-side desktop packages; tests default to stable.
const std = @import("std");
const root = @import("root");
pub const name = if (@hasDecl(root, "aqueous_instance_name")) root.aqueous_instance_name else "aqueous";
pub const suffix = if (std.mem.eql(u8, name, "aqueous")) "" else if (std.mem.eql(u8, name, "aqueous-git")) "-git" else if (std.mem.eql(u8, name, "aqueous-intel-git")) "-intel-git" else @compileError("Unsupported welcome instance");
pub const desktop = if (suffix.len == 0) "Aqueous" else if (std.mem.eql(u8, suffix, "-git")) "Aqueous-Git" else "Aqueous-Intel-Git";
pub const app_id = if (suffix.len == 0) "org.aqueous.Welcome" else if (std.mem.eql(u8, suffix, "-git")) "org.aqueous.Git.Welcome" else "org.aqueous.IntelGit.Welcome";
pub const runtime_relative = if (suffix.len == 0) "../lib/aqueous/session-runtime.sh" else "../session-runtime.sh";

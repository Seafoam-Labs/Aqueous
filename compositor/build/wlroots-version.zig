// SPDX-FileCopyrightText: 2020 Isaac Freund
// SPDX-License-Identifier: MIT
// Compatibility adapter for zig-wlroots v0.20.2 (MIT).
const c = @import("wlroots_headers");

pub const str = c.WLR_VERSION_STR;

pub const major = c.WLR_VERSION_MAJOR;
pub const minor = c.WLR_VERSION_MINOR;
pub const micro = c.WLR_VERSION_MICRO;

pub const num = c.WLR_VERSION_NUM;

extern fn wlr_version_get_major() c_int;
pub const runtimeMajor = wlr_version_get_major;

extern fn wlr_version_get_minor() c_int;
pub const runtimeMinor = wlr_version_get_minor;

extern fn wlr_version_get_micro() c_int;
pub const runtimeMicro = wlr_version_get_micro;

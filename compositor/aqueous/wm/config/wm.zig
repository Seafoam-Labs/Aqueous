// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const layout = @import("layout.zig");

pub const max_mappings = 32;

pub const Text = struct {
    bytes: [256]u8 = undefined,
    len: u16 = 0,

    pub fn set(text: *Text, value: []const u8) bool {
        if (value.len > text.bytes.len) return false;
        @memcpy(text.bytes[0..value.len], value);
        text.len = @intCast(value.len);
        return true;
    }

    pub fn slice(text: *const Text) []const u8 {
        return text.bytes[0..text.len];
    }

    pub fn empty(text: *const Text) bool {
        return text.len == 0;
    }
};

pub const Struts = struct {
    top: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,
    right: i32 = 0,

    pub fn apply(struts: Struts, rect: @import("../layout/types.zig").Rect) @import("../layout/types.zig").Rect {
        return .{
            .x = rect.x + struts.left,
            .y = rect.y + struts.top,
            .width = @max(1, rect.width - struts.left - struts.right),
            .height = @max(1, rect.height - struts.top - struts.bottom),
        };
    }
};

pub const Device = struct {
    accel_profile: enum { unset, adaptive, flat } = .unset,
    accel_speed: ?f64 = null,
    natural_scroll: ?bool = null,
    tap: ?bool = null,
    dwt: ?bool = null,
    left_handed: ?bool = null,
    click_method: enum { unset, clickfinger, button_areas } = .unset,
    scroll_method: enum { unset, two_finger, edge, no_scroll } = .unset,
    middle_emulation: ?bool = null,
};

pub const Input = struct {
    focus_follows_mouse: bool = false,
    focus_new_windows: bool = false,
    focus_new_windows_set: bool = false,
    pointer_acceleration: bool = false,
    pointer_acceleration_factor: f64 = 0,
    /// Keyboard repeat rate in characters per second. Zero disables repeat.
    repeat_rate: u31 = 40,
    repeat_rate_set: bool = false,
    /// Delay before keyboard repeat begins, in milliseconds.
    repeat_delay: u31 = 400,
    repeat_delay_set: bool = false,
    mouse: Device = .{},
    touchpad: Device = .{},
    trackpoint: Device = .{},
    xkb_layout: Text = .{},
    xkb_variant: Text = .{},
    xkb_options: Text = .{},
    num_lock_state: bool = false,
};

pub const OutputLayout = struct {
    name: Text = .{},
    edid: Text = .{},
    make: Text = .{},
    model: Text = .{},
    serial: Text = .{},
    layout_id: layout.LayoutId = .tile,

    pub fn matches(entry: *const OutputLayout, identity: OutputIdentity) bool {
        if (!entry.edid.empty()) return eqlIgnoreCase(entry.edid.slice(), identity.edid orelse "");
        const has_metadata = !entry.make.empty() or !entry.model.empty() or !entry.serial.empty();
        if (has_metadata) {
            if (!entry.make.empty() and !eqlIgnoreCase(entry.make.slice(), identity.make orelse "")) return false;
            if (!entry.model.empty() and !eqlIgnoreCase(entry.model.slice(), identity.model orelse "")) return false;
            if (!entry.serial.empty() and !eqlIgnoreCase(entry.serial.slice(), identity.serial orelse "")) return false;
            return true;
        }
        return !entry.name.empty() and std.mem.eql(u8, entry.name.slice(), identity.name orelse "");
    }
};

pub const OutputIdentity = struct {
    name: ?[]const u8 = null,
    edid: ?[]const u8 = null,
    make: ?[]const u8 = null,
    model: ?[]const u8 = null,
    serial: ?[]const u8 = null,
};

pub const WorkspaceLayout = struct {
    output: Text = .{},
    number: u32 = 0,
    layout_id: layout.LayoutId = .tile,
};

pub const Snapshot = struct {
    struts: Struts = .{},
    input: Input = .{},
    outputs: [max_mappings]OutputLayout = undefined,
    output_count: u8 = 0,
    workspaces: [max_mappings]WorkspaceLayout = undefined,
    workspace_count: u8 = 0,
    layout_path: Text = .{},
    rules_path: Text = .{},
    input_path: Text = .{},
    force_ssd: bool = false,
    fullscreen_hides_bar: bool = true,
    maximize_full_output: bool = false,
    blur_enabled: bool = false,
    blur_radius: i32 = 5,
    blur_passes: i32 = 3,
    blur_noise: f64 = 0,
    blur_contrast: f64 = 1,
    blur_brightness: f64 = 1,
    blur_vibrancy: f64 = 0,
    blur_vibrancy_darkness: f64 = 0,
    opacity_enabled: bool = false,
    opacity: f64 = 0.9,
    opacity_focus_sensitive: bool = false,
    opacity_focused: f64 = 1,
    opacity_unfocused: f64 = 0.9,
    workspace_transition_enabled: bool = true,
    workspace_transition_rate: f64 = 0,

    pub fn resolveOutput(snapshot: *const Snapshot, identity: OutputIdentity) ?layout.LayoutId {
        // Name matches have precedence even if a metadata selector appeared first.
        if (identity.name) |name| for (snapshot.outputs[0..snapshot.output_count]) |*entry| {
            if (!entry.name.empty() and std.mem.eql(u8, entry.name.slice(), name)) return entry.layout_id;
        };
        for (snapshot.outputs[0..snapshot.output_count]) |*entry| if (entry.matches(identity)) return entry.layout_id;
        return null;
    }

    pub fn resolveWorkspace(snapshot: *const Snapshot, output_name: ?[]const u8, number: u32) ?layout.LayoutId {
        if (number == 0) return null;
        if (output_name) |name| for (snapshot.workspaces[0..snapshot.workspace_count]) |*entry| {
            if (entry.number == number and !entry.output.empty() and std.mem.eql(u8, entry.output.slice(), name)) return entry.layout_id;
        };
        for (snapshot.workspaces[0..snapshot.workspace_count]) |*entry| {
            if (entry.number == number and entry.output.empty()) return entry.layout_id;
        }
        return null;
    }
};

const Section = union(enum) { none, layout, rules, struts, state, blur, opacity, workspace_transition, input, device: enum { mouse, touchpad, trackpoint }, output, workspace };

pub fn apply(snapshot: *Snapshot, layout_snapshot: *layout.Snapshot, source: []const u8) void {
    var section: Section = .none;
    var output: ?OutputLayout = null;
    var workspace: ?WorkspaceLayout = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = cleanLine(raw);
        if (line.len == 0) continue;
        if (line[0] == '[') {
            flushOutput(snapshot, &output);
            flushWorkspace(snapshot, &workspace);
            if (std.mem.eql(u8, line, "[[output]]")) {
                section = .output;
                output = .{};
                continue;
            }
            if (std.mem.eql(u8, line, "[[workspace]]")) {
                section = .workspace;
                workspace = .{};
                continue;
            }
            if (line[line.len - 1] != ']') {
                section = .none;
                continue;
            }
            const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            section = parseSection(name);
            continue;
        }
        const equal = indexUnquoted(line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equal], " \t");
        const value = unquote(std.mem.trim(u8, line[equal + 1 ..], " \t"));
        switch (section) {
            .layout => {
                if (std.mem.eql(u8, key, "path")) _ = snapshot.layout_path.set(value);
                if (std.mem.eql(u8, key, "force_ssd")) snapshot.force_ssd = parseBool(value) orelse snapshot.force_ssd;
            },
            .rules => if (std.mem.eql(u8, key, "path")) {
                _ = snapshot.rules_path.set(value);
            },
            .struts => applyStrut(&snapshot.struts, key, value),
            .state => {
                if (std.mem.eql(u8, key, "fullscreen_hides_bar")) snapshot.fullscreen_hides_bar = parseBool(value) orelse snapshot.fullscreen_hides_bar;
                if (std.mem.eql(u8, key, "maximize_full_output")) snapshot.maximize_full_output = parseBool(value) orelse snapshot.maximize_full_output;
            },
            .blur => {
                if (std.mem.eql(u8, key, "enabled")) snapshot.blur_enabled = parseBool(value) orelse snapshot.blur_enabled;
                if (std.mem.eql(u8, key, "radius")) snapshot.blur_radius = parseNonNegative(value) orelse snapshot.blur_radius;
                if (std.mem.eql(u8, key, "passes")) snapshot.blur_passes = parseNonNegative(value) orelse snapshot.blur_passes;
                if (std.mem.eql(u8, key, "noise")) snapshot.blur_noise = parseUnit(value) orelse snapshot.blur_noise;
                if (std.mem.eql(u8, key, "contrast")) snapshot.blur_contrast = parseRange(value, 0, 2) orelse snapshot.blur_contrast;
                if (std.mem.eql(u8, key, "brightness")) snapshot.blur_brightness = parseRange(value, 0, 2) orelse snapshot.blur_brightness;
                if (std.mem.eql(u8, key, "vibrancy")) snapshot.blur_vibrancy = parseUnit(value) orelse snapshot.blur_vibrancy;
                if (std.mem.eql(u8, key, "vibrancy_darkness")) snapshot.blur_vibrancy_darkness = parseUnit(value) orelse snapshot.blur_vibrancy_darkness;
            },
            .opacity => applyOpacity(snapshot, key, value),
            .workspace_transition => {
                if (std.mem.eql(u8, key, "enabled")) snapshot.workspace_transition_enabled = parseBool(value) orelse snapshot.workspace_transition_enabled;
                if (std.mem.eql(u8, key, "rate")) snapshot.workspace_transition_rate = parseNonNegativeFloat(value) orelse snapshot.workspace_transition_rate;
            },
            .input => {
                if (std.mem.eql(u8, key, "path")) _ = snapshot.input_path.set(value) else applyInput(&snapshot.input, key, value);
            },
            .device => |kind| applyDevice(switch (kind) {
                .mouse => &snapshot.input.mouse,
                .touchpad => &snapshot.input.touchpad,
                .trackpoint => &snapshot.input.trackpoint,
            }, key, value),
            .output => if (output) |*entry| applyOutput(entry, key, value),
            .workspace => if (workspace) |*entry| applyWorkspace(entry, key, value),
            .none => {},
        }
    }
    flushOutput(snapshot, &output);
    flushWorkspace(snapshot, &workspace);
    // The layout parser owns common and per-layout options.
    layout.apply(layout_snapshot, source);
}

fn parseSection(name: []const u8) Section {
    if (std.mem.eql(u8, name, "layout")) return .layout;
    if (std.mem.eql(u8, name, "rules")) return .rules;
    if (std.mem.eql(u8, name, "struts")) return .struts;
    if (std.mem.eql(u8, name, "state")) return .state;
    if (std.mem.eql(u8, name, "blur")) return .blur;
    if (std.mem.eql(u8, name, "opacity")) return .opacity;
    if (std.mem.eql(u8, name, "workspace_transition")) return .workspace_transition;
    if (std.mem.eql(u8, name, "input")) return .input;
    if (std.mem.eql(u8, name, "input.mouse")) return .{ .device = .mouse };
    if (std.mem.eql(u8, name, "input.touchpad")) return .{ .device = .touchpad };
    if (std.mem.eql(u8, name, "input.trackpoint")) return .{ .device = .trackpoint };
    return .none;
}

fn applyStrut(struts: *Struts, key: []const u8, value: []const u8) void {
    const parsed = parseNonNegative(value) orelse return;
    if (std.mem.eql(u8, key, "top")) struts.top = parsed;
    if (std.mem.eql(u8, key, "bottom")) struts.bottom = parsed;
    if (std.mem.eql(u8, key, "left")) struts.left = parsed;
    if (std.mem.eql(u8, key, "right")) struts.right = parsed;
}

fn applyOpacity(snapshot: *Snapshot, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "enabled")) snapshot.opacity_enabled = parseBool(value) orelse snapshot.opacity_enabled;
    if (std.mem.eql(u8, key, "focus_sensitive")) snapshot.opacity_focus_sensitive = parseBool(value) orelse snapshot.opacity_focus_sensitive;
    if (std.mem.eql(u8, key, "value")) snapshot.opacity = parseUnit(value) orelse snapshot.opacity;
    if (std.mem.eql(u8, key, "focused")) snapshot.opacity_focused = parseUnit(value) orelse snapshot.opacity_focused;
    if (std.mem.eql(u8, key, "unfocused")) snapshot.opacity_unfocused = parseUnit(value) orelse snapshot.opacity_unfocused;
}

fn applyInput(input: *Input, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "focus_follows_mouse")) input.focus_follows_mouse = parseBool(value) orelse input.focus_follows_mouse;
    if (std.mem.eql(u8, key, "focus_new_windows")) if (parseBool(value)) |parsed| {
        input.focus_new_windows = parsed;
        input.focus_new_windows_set = true;
    };
    if (std.mem.eql(u8, key, "pointer_acceleration")) input.pointer_acceleration = parseBool(value) orelse input.pointer_acceleration;
    if (std.mem.eql(u8, key, "pointer_acceleration_factor")) input.pointer_acceleration_factor = parseSpeed(value) orelse input.pointer_acceleration_factor;
    if (std.mem.eql(u8, key, "repeat_rate") or std.mem.eql(u8, key, "repeat-rate")) if (parseU31(value)) |parsed| {
        input.repeat_rate = parsed;
        input.repeat_rate_set = true;
    };
    if (std.mem.eql(u8, key, "repeat_delay") or std.mem.eql(u8, key, "repeat-delay")) if (parseU31(value)) |parsed| {
        input.repeat_delay = parsed;
        input.repeat_delay_set = true;
    };
    if (std.mem.eql(u8, key, "xkb_layout")) _ = input.xkb_layout.set(value);
    if (std.mem.eql(u8, key, "xkb_variant")) _ = input.xkb_variant.set(value);
    if (std.mem.eql(u8, key, "xkb_options")) _ = input.xkb_options.set(value);
}

fn applyDevice(device: *Device, raw_key: []const u8, value: []const u8) void {
    var key_buf: [64]u8 = undefined;
    if (raw_key.len > key_buf.len) return;
    for (raw_key, 0..) |char, i| key_buf[i] = if (char == '-') '_' else char;
    const key = key_buf[0..raw_key.len];
    if (std.mem.eql(u8, key, "accel_profile")) {
        if (std.mem.eql(u8, value, "flat")) device.accel_profile = .flat;
        if (std.mem.eql(u8, value, "adaptive")) device.accel_profile = .adaptive;
    }
    if (std.mem.eql(u8, key, "accel_speed")) device.accel_speed = parseSpeed(value) orelse device.accel_speed;
    if (std.mem.eql(u8, key, "natural_scroll")) device.natural_scroll = parseBool(value) orelse device.natural_scroll;
    if (std.mem.eql(u8, key, "tap")) device.tap = parseBool(value) orelse device.tap;
    if (std.mem.eql(u8, key, "dwt")) device.dwt = parseBool(value) orelse device.dwt;
    if (std.mem.eql(u8, key, "left_handed")) device.left_handed = parseBool(value) orelse device.left_handed;
    if (std.mem.eql(u8, key, "middle_emulation")) device.middle_emulation = parseBool(value) orelse device.middle_emulation;
    if (std.mem.eql(u8, key, "click_method")) {
        if (std.mem.eql(u8, value, "clickfinger")) device.click_method = .clickfinger;
        if (std.mem.eql(u8, value, "button-areas") or std.mem.eql(u8, value, "button_areas")) device.click_method = .button_areas;
    }
    if (std.mem.eql(u8, key, "scroll_method")) {
        if (std.mem.eql(u8, value, "two-finger") or std.mem.eql(u8, value, "two_finger")) device.scroll_method = .two_finger;
        if (std.mem.eql(u8, value, "edge")) device.scroll_method = .edge;
        if (std.mem.eql(u8, value, "no-scroll") or std.mem.eql(u8, value, "no_scroll")) device.scroll_method = .no_scroll;
    }
}

fn applyOutput(output: *OutputLayout, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "name")) _ = output.name.set(value);
    if (std.mem.eql(u8, key, "edid")) _ = output.edid.set(value);
    if (std.mem.eql(u8, key, "make")) _ = output.make.set(value);
    if (std.mem.eql(u8, key, "model")) _ = output.model.set(value);
    if (std.mem.eql(u8, key, "serial")) _ = output.serial.set(value);
    if (std.mem.eql(u8, key, "layout")) output.layout_id = parseLayout(value) orelse output.layout_id;
}

fn applyWorkspace(workspace: *WorkspaceLayout, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "output")) _ = workspace.output.set(value);
    if (std.mem.eql(u8, key, "workspace")) workspace.number = std.fmt.parseInt(u32, value, 10) catch workspace.number;
    if (std.mem.eql(u8, key, "layout")) workspace.layout_id = parseLayout(value) orelse workspace.layout_id;
}

fn flushOutput(snapshot: *Snapshot, pending: *?OutputLayout) void {
    const entry = pending.* orelse return;
    pending.* = null;
    if (snapshot.output_count == max_mappings) return;
    if (entry.name.empty() and entry.edid.empty() and entry.make.empty() and entry.model.empty() and entry.serial.empty()) return;
    snapshot.outputs[snapshot.output_count] = entry;
    snapshot.output_count += 1;
}

fn flushWorkspace(snapshot: *Snapshot, pending: *?WorkspaceLayout) void {
    const entry = pending.* orelse return;
    pending.* = null;
    if (snapshot.workspace_count == max_mappings or entry.number == 0) return;
    snapshot.workspaces[snapshot.workspace_count] = entry;
    snapshot.workspace_count += 1;
}

pub fn cleanLine(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    const comment = indexUnquoted(trimmed, '#') orelse trimmed.len;
    return std.mem.trim(u8, trimmed[0..comment], " \t\r");
}

pub fn indexUnquoted(value: []const u8, needle: u8) ?usize {
    var quote: ?u8 = null;
    var escaped = false;
    for (value, 0..) |char, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (char == '\\' and quote == '"') {
            escaped = true;
            continue;
        }
        if (quote) |q| {
            if (char == q) quote = null;
            continue;
        }
        if (char == '"' or char == '\'') {
            quote = char;
            continue;
        }
        if (char == needle) return i;
    }
    return null;
}

pub fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) return value[1 .. value.len - 1];
    return value;
}

fn parseLayout(value: []const u8) ?layout.LayoutId {
    if (std.mem.eql(u8, value, "tile")) return .tile;
    if (std.mem.eql(u8, value, "monocle")) return .monocle;
    if (std.mem.eql(u8, value, "grid")) return .grid;
    if (std.mem.eql(u8, value, "rows")) return .rows;
    if (std.mem.eql(u8, value, "dwindle")) return .dwindle;
    if (std.mem.eql(u8, value, "reverse-dwindle") or std.mem.eql(u8, value, "reverse_dwindle")) return .reverse_dwindle;
    if (std.mem.eql(u8, value, "scrolling")) return .scrolling;
    if (std.mem.eql(u8, value, "float") or std.mem.eql(u8, value, "floating")) return .floating;
    if (std.mem.eql(u8, value, "game-mode") or std.mem.eql(u8, value, "game_mode")) return .game_mode;
    if (std.mem.eql(u8, value, "composable")) return .composable;
    return null;
}

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}
fn parseNonNegative(value: []const u8) ?i32 {
    const result = std.fmt.parseInt(i32, value, 10) catch return null;
    return if (result >= 0) result else null;
}
fn parseNonNegativeFloat(value: []const u8) ?f64 {
    const result = std.fmt.parseFloat(f64, value) catch return null;
    return if (std.math.isFinite(result) and result >= 0) result else null;
}
fn parseU31(value: []const u8) ?u31 {
    return std.fmt.parseInt(u31, value, 10) catch null;
}
fn parseUnit(value: []const u8) ?f64 {
    return parseRange(value, 0, 1);
}
fn parseRange(value: []const u8, minimum: f64, maximum: f64) ?f64 {
    const result = std.fmt.parseFloat(f64, value) catch return null;
    return if (std.math.isFinite(result) and result >= minimum and result <= maximum) result else null;
}
fn parseSpeed(value: []const u8) ?f64 {
    const result = std.fmt.parseFloat(f64, value) catch return null;
    return if (std.math.isFinite(result) and result >= -1 and result <= 1) result else null;
}
fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "wm and input config validates mappings, struts, and device settings" {
    var wm_snapshot: Snapshot = .{};
    var layout_snapshot: layout.Snapshot = .{};
    apply(&wm_snapshot, &layout_snapshot,
        \\[struts]
        \\top = 32
        \\left = -2
        \\[input]
        \\focus_follows_mouse = true
        \\focus_new_windows = true
        \\repeat_rate = 30
        \\repeat_delay = 275
        \\xkb_layout = "us,de"
        \\[input.touchpad]
        \\accel-speed = 0.5
        \\natural_scroll = true
        \\[[output]]
        \\name = "DP-1"
        \\layout = "grid"
        \\[[workspace]]
        \\output = "DP-1"
        \\workspace = 2
        \\layout = "monocle"
        \\[[workspace]]
        \\workspace = 3
        \\layout = "composable"
        \\[[workspace]]
        \\workspace = 4
        \\layout = "reverse-dwindle"
        \\[[workspace]]
        \\workspace = 5
        \\layout = "reverse_dwindle"
    );
    try std.testing.expectEqual(@as(i32, 32), wm_snapshot.struts.top);
    try std.testing.expectEqual(@as(i32, 0), wm_snapshot.struts.left);
    try std.testing.expect(wm_snapshot.input.focus_follows_mouse);
    try std.testing.expect(wm_snapshot.input.focus_new_windows);
    try std.testing.expect(wm_snapshot.input.focus_new_windows_set);
    try std.testing.expectEqual(@as(u31, 30), wm_snapshot.input.repeat_rate);
    try std.testing.expectEqual(@as(u31, 275), wm_snapshot.input.repeat_delay);
    try std.testing.expectEqualStrings("us,de", wm_snapshot.input.xkb_layout.slice());
    try std.testing.expectEqual(@as(?f64, 0.5), wm_snapshot.input.touchpad.accel_speed);
    try std.testing.expectEqual(layout.LayoutId.grid, wm_snapshot.resolveOutput(.{ .name = "DP-1" }).?);
    try std.testing.expectEqual(layout.LayoutId.monocle, wm_snapshot.resolveWorkspace("DP-1", 2).?);
    try std.testing.expectEqual(layout.LayoutId.composable, wm_snapshot.resolveWorkspace(null, 3).?);
    try std.testing.expectEqual(layout.LayoutId.reverse_dwindle, wm_snapshot.resolveWorkspace(null, 4).?);
    try std.testing.expectEqual(layout.LayoutId.reverse_dwindle, wm_snapshot.resolveWorkspace(null, 5).?);
}

test "new-window focus defaults to disabled" {
    const snapshot: Snapshot = .{};
    try std.testing.expect(!snapshot.input.focus_new_windows);
    try std.testing.expect(!snapshot.input.focus_new_windows_set);
}

test "blur appearance validates ranges and preserves neutral defaults" {
    var wm_snapshot: Snapshot = .{};
    var layout_snapshot: layout.Snapshot = .{};
    try std.testing.expectEqual(@as(f64, 0), wm_snapshot.blur_noise);
    try std.testing.expectEqual(@as(f64, 1), wm_snapshot.blur_contrast);
    try std.testing.expectEqual(@as(f64, 1), wm_snapshot.blur_brightness);
    try std.testing.expectEqual(@as(f64, 0), wm_snapshot.blur_vibrancy);
    try std.testing.expectEqual(@as(f64, 0), wm_snapshot.blur_vibrancy_darkness);

    apply(&wm_snapshot, &layout_snapshot,
        \\[blur]
        \\noise = 0.125
        \\contrast = 1.5
        \\brightness = 0.75
        \\vibrancy = 0.4
        \\vibrancy_darkness = 0.6
    );
    try std.testing.expectEqual(@as(f64, 0.125), wm_snapshot.blur_noise);
    try std.testing.expectEqual(@as(f64, 1.5), wm_snapshot.blur_contrast);
    try std.testing.expectEqual(@as(f64, 0.75), wm_snapshot.blur_brightness);
    try std.testing.expectEqual(@as(f64, 0.4), wm_snapshot.blur_vibrancy);
    try std.testing.expectEqual(@as(f64, 0.6), wm_snapshot.blur_vibrancy_darkness);

    apply(&wm_snapshot, &layout_snapshot,
        \\[blur]
        \\noise = -0.1
        \\contrast = 2.1
        \\brightness = nan
        \\vibrancy = 1.1
        \\vibrancy_darkness = -1
    );
    try std.testing.expectEqual(@as(f64, 0.125), wm_snapshot.blur_noise);
    try std.testing.expectEqual(@as(f64, 1.5), wm_snapshot.blur_contrast);
    try std.testing.expectEqual(@as(f64, 0.75), wm_snapshot.blur_brightness);
    try std.testing.expectEqual(@as(f64, 0.4), wm_snapshot.blur_vibrancy);
    try std.testing.expectEqual(@as(f64, 0.6), wm_snapshot.blur_vibrancy_darkness);
}

test "comments inside quoted values are preserved" {
    try std.testing.expectEqualStrings("key = \"a#b\"", cleanLine(" key = \"a#b\" # comment"));
}

// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const wm = @import("wm.zig");

pub const max_bindings = 160;
pub const max_exec = 32;
pub const max_gestures = 16;
pub const default_screenshot_command = "grim -g \"$(slurp)\" - | wl-copy";

pub const GestureKind = enum { swipe, pinch };

pub const GestureDirection = enum { left, right, up, down, in, out };

pub const GestureBinding = struct {
    kind: GestureKind = undefined,
    direction: GestureDirection = undefined,
    fingers: u8 = undefined,
    verb: wm.Text = .{},
};

pub const Binding = struct {
    modifiers: u32 = 0,
    keysym: u32 = 0,
    verb: wm.Text = .{},
};

pub const ExecWhen = enum { startup, reload, always };
pub const Exec = struct {
    name: wm.Text = .{},
    command: wm.Text = .{},
    when: ExecWhen = .startup,
    once: bool = true,
    restart: bool = false,
    log_path: wm.Text = .{},
    env: wm.Text = .{},
};

pub const Snapshot = struct {
    bindings: [max_bindings]Binding = undefined,
    binding_count: u16 = 0,
    exec: [max_exec]Exec = undefined,
    exec_count: u8 = 0,
    gestures: [max_gestures]GestureBinding = undefined,
    gestures_count: u8 = 0,
    toggle_start_menu: wm.Text = .{},
    spawn_terminal: wm.Text = .{},
    screenshot: wm.Text = .{},
    lock_screen: wm.Text = .{},
    primary_modifier: u32 = 64,

    pub fn find(snapshot: *const Snapshot, keysym: u32, modifiers: u32) ?[]const u8 {
        for (snapshot.bindings[0..snapshot.binding_count]) |*binding| {
            if (binding.keysym == keysym and binding.modifiers == modifiers) return binding.verb.slice();
        }
        return null;
    }

    pub fn hasGesture(snapshot: *const Snapshot, kind: GestureKind, fingers: u8) bool {
        for (snapshot.gestures[0..snapshot.gestures_count]) |gesture| {
            if (gesture.kind == kind and gesture.fingers == fingers) return true;
        }
        return false;
    }

    pub fn findGesture(snapshot: *const Snapshot, kind: GestureKind, direction: GestureDirection, fingers: u8) ?[]const u8 {
        for (snapshot.gestures[0..snapshot.gestures_count]) |*gesture| {
            if (gesture.kind == kind and gesture.direction == direction and gesture.fingers == fingers) return gesture.verb.slice();
        }
        return null;
    }
};

const defaults = [_]struct { []const u8, []const u8 }{
    .{ "toggle_start_menu", "Super+Space" },                .{ "spawn_terminal", "Super+Return" },
    .{ "screenshot", "Print" },                             .{ "toggle_overview", "Super+W" },
    .{ "close_focused", "Super+Q" },                        .{ "cycle_focus", "Super+Tab" },
    .{ "focus_left", "Super+H" },                           .{ "focus_right", "Super+L" },
    .{ "focus_up", "Super+K" },                             .{ "focus_down", "Super+J" },
    .{ "scroll_viewport_left", "Super+Comma" },             .{ "scroll_viewport_right", "Super+Period" },
    .{ "scroll_viewport_left_arrow", "Super+Left" },        .{ "scroll_viewport_right_arrow", "Super+Right" },
    .{ "scroll_viewport_up", "Super+Up" },                  .{ "scroll_viewport_down", "Super+Down" },
    .{ "consume_window_into_column", "Super+Ctrl+J" },      .{ "expel_window_from_column", "Super+Ctrl+K" },
    .{ "move_window_left", "Super+Shift+Left" },            .{ "move_window_right", "Super+Shift+Right" },
    .{ "move_window_up", "Super+Shift+Up" },                .{ "move_window_down", "Super+Shift+Down" },
    .{ "reload_config", "Super+R" },                        .{ "focus_workspace_1", "Super+1" },
    .{ "focus_workspace_2", "Super+2" },                    .{ "focus_workspace_3", "Super+3" },
    .{ "focus_workspace_4", "Super+4" },                    .{ "focus_workspace_5", "Super+5" },
    .{ "focus_workspace_6", "Super+6" },                    .{ "focus_workspace_7", "Super+7" },
    .{ "focus_workspace_8", "Super+8" },                    .{ "focus_workspace_9", "Super+9" },
    .{ "move_to_workspace_1", "Super+Shift+1" },            .{ "move_to_workspace_2", "Super+Shift+2" },
    .{ "move_to_workspace_3", "Super+Shift+3" },            .{ "move_to_workspace_4", "Super+Shift+4" },
    .{ "move_to_workspace_5", "Super+Shift+5" },            .{ "move_to_workspace_6", "Super+Shift+6" },
    .{ "move_to_workspace_7", "Super+Shift+7" },            .{ "move_to_workspace_8", "Super+Shift+8" },
    .{ "move_to_workspace_9", "Super+Shift+9" },            .{ "focus_workspace_up", "Super+Bracketleft" },
    .{ "focus_workspace_down", "Super+Bracketright" },      .{ "focus_previous_workspace", "Super+BackSpace" },
    .{ "move_to_workspace_up", "Super+Shift+Bracketleft" }, .{ "move_to_workspace_down", "Super+Shift+Bracketright" },
    .{ "focus_output_left", "Super+Ctrl+Comma" },           .{ "focus_output_right", "Super+Ctrl+Period" },
    .{ "move_to_output_left", "Super+Shift+Comma" },        .{ "move_to_output_right", "Super+Shift+Period" },
    .{ "toggle_fullscreen", "Super+Shift+F" },              .{ "toggle_maximize", "Super+Shift+M" },
    .{ "toggle_scrolling_full_width", "Super+Shift+Z" },    .{ "toggle_floating", "Super+Shift+Space" },
    .{ "toggle_minimize", "Super+N" },                      .{ "unminimize_last", "Super+Shift+N" },
    .{ "lock_screen", "Super+Ctrl+L" },                     .{ "untrap_pointer", "Super+grave" },
};

pub fn initDefaults(snapshot: *Snapshot) void {
    snapshot.primary_modifier = primaryMask();
    _ = snapshot.screenshot.set(default_screenshot_command);
    for (defaults) |entry| addBuiltin(snapshot, entry[0], entry[1]);
}

pub fn addBuiltin(snapshot: *Snapshot, action: []const u8, chord: []const u8) void {
    removeBuiltin(snapshot, action);
    var verb_buf: [280]u8 = undefined;
    const verb = std.fmt.bufPrint(&verb_buf, "builtin:{s}", .{action}) catch return;
    addBinding(snapshot, chord, verb);
}

pub fn addBuiltinList(snapshot: *Snapshot, action: []const u8, value: []const u8) void {
    removeBuiltin(snapshot, action);
    var rest = std.mem.trim(u8, value, " \t");
    if (rest.len == 0) return;
    if (rest[0] != '[') {
        addBuiltinNoRemove(snapshot, action, unquote(rest));
        return;
    }
    if (rest.len < 2 or rest[rest.len - 1] != ']') return;
    rest = rest[1 .. rest.len - 1];
    var parts = std.mem.splitScalar(u8, rest, ',');
    while (parts.next()) |part| addBuiltinNoRemove(snapshot, action, unquote(std.mem.trim(u8, part, " \t")));
}

fn addBuiltinNoRemove(snapshot: *Snapshot, action: []const u8, chord: []const u8) void {
    var verb_buf: [280]u8 = undefined;
    const verb = std.fmt.bufPrint(&verb_buf, "builtin:{s}", .{action}) catch return;
    addBinding(snapshot, chord, verb);
}

pub fn addBinding(snapshot: *Snapshot, chord: []const u8, verb: []const u8) void {
    if (snapshot.binding_count == max_bindings) return;
    const parsed = parseChord(chord) orelse return;
    var binding: Binding = .{ .modifiers = parsed.modifiers, .keysym = parsed.keysym };
    if (!binding.verb.set(verb)) return;
    // Last declaration wins, matching the C# registrar.
    var i: usize = 0;
    while (i < snapshot.binding_count) : (i += 1) {
        if (snapshot.bindings[i].modifiers == parsed.modifiers and snapshot.bindings[i].keysym == parsed.keysym) {
            snapshot.bindings[i] = binding;
            return;
        }
    }
    snapshot.bindings[snapshot.binding_count] = binding;
    snapshot.binding_count += 1;
}

pub fn addGesture(snapshot: *Snapshot, kind: GestureKind, direction: GestureDirection, fingers: u8, verb: []const u8) void {
    var gesture: GestureBinding = .{ .direction = direction, .kind = kind, .fingers = fingers };
    if (!gesture.verb.set(verb)) return;
    var i: usize = 0;
    while (i < snapshot.gestures_count) : (i += 1) {
        if (snapshot.gestures[i].direction == gesture.direction and snapshot.gestures[i].fingers == gesture.fingers and snapshot.gestures[i].kind == gesture.kind) {
            snapshot.gestures[i] = gesture;
            return;
        }
    }
    if (snapshot.gestures_count == max_gestures) return;
    snapshot.gestures[snapshot.gestures_count] = gesture;
    snapshot.gestures_count += 1;
}

fn removeBuiltin(snapshot: *Snapshot, action: []const u8) void {
    var buf: [280]u8 = undefined;
    const verb = std.fmt.bufPrint(&buf, "builtin:{s}", .{action}) catch return;
    var write: usize = 0;
    for (snapshot.bindings[0..snapshot.binding_count]) |binding| {
        if (std.mem.eql(u8, binding.verb.slice(), verb)) continue;
        snapshot.bindings[write] = binding;
        write += 1;
    }
    snapshot.binding_count = @intCast(write);
}

pub const Chord = struct { modifiers: u32, keysym: u32 };
pub fn parseChord(text: []const u8) ?Chord {
    var modifiers: u32 = 0;
    var keysym: ?u32 = null;
    var parts = std.mem.splitScalar(u8, text, '+');
    while (parts.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t");
        if (std.ascii.eqlIgnoreCase(token, "super") or std.ascii.eqlIgnoreCase(token, "mod4") or std.ascii.eqlIgnoreCase(token, "logo") or std.ascii.eqlIgnoreCase(token, "win")) modifiers |= primaryMask() else if (std.ascii.eqlIgnoreCase(token, "ctrl") or std.ascii.eqlIgnoreCase(token, "control")) modifiers |= 4 else if (std.ascii.eqlIgnoreCase(token, "alt") or std.ascii.eqlIgnoreCase(token, "mod1")) modifiers |= if (primaryMask() == 8) @as(u32, 8) else 8 else if (std.ascii.eqlIgnoreCase(token, "shift")) modifiers |= 1 else {
            if (keysym != null) return null;
            keysym = resolveKeysym(token) orelse return null;
        }
    }
    return .{ .modifiers = modifiers, .keysym = keysym orelse return null };
}

fn primaryMask() u32 {
    if (@import("builtin").is_test) return 64;
    const value = std.c.getenv("AQUEOUS_MOD") orelse return 64;
    return if (std.ascii.eqlIgnoreCase(std.mem.span(value), "alt")) 8 else 64;
}

fn resolveKeysym(token: []const u8) ?u32 {
    const names = .{
        .{ "return", 0xff0d },                  .{ "enter", 0xff0d },                     .{ "space", 0x20 },                      .{ "tab", 0xff09 },
        .{ "escape", 0xff1b },                  .{ "esc", 0xff1b },                       .{ "backspace", 0xff08 },                .{ "delete", 0xffff },
        .{ "capslock", 0xffe5 },                .{ "caps_lock", 0xffe5 },                 .{ "caps", 0xffe5 },                     .{ "print", 0xff61 },
        .{ "printscreen", 0xff61 },             .{ "left", 0xff51 },                      .{ "up", 0xff52 },                       .{ "right", 0xff53 },
        .{ "down", 0xff54 },                    .{ "home", 0xff50 },                      .{ "end", 0xff57 },                      .{ "pageup", 0xff55 },
        .{ "pagedown", 0xff56 },                .{ "comma", 0x2c },                       .{ "period", 0x2e },                     .{ "semicolon", 0x3b },
        .{ "slash", 0x2f },                     .{ "minus", 0x2d },                       .{ "equal", 0x3d },                      .{ "plus", 0x2b },
        .{ "bracketleft", 0x5b },               .{ "bracketright", 0x5d },                .{ "grave", 0x60 },                      .{ "apostrophe", 0x27 },
        .{ "backslash", 0x5c },                 .{ "xf86audioraisevolume", 0x1008ff13 },  .{ "xf86audiolowervolume", 0x1008ff11 }, .{ "xf86audiomute", 0x1008ff12 },
        .{ "xf86audiomicmute", 0x1008ffb2 },    .{ "xf86audioplay", 0x1008ff14 },         .{ "xf86audiopause", 0x1008ff31 },       .{ "xf86audiostop", 0x1008ff15 },
        .{ "xf86audionext", 0x1008ff17 },       .{ "xf86audioprev", 0x1008ff16 },         .{ "xf86monbrightnessup", 0x1008ff02 },  .{ "xf86monbrightnessdown", 0x1008ff03 },
        .{ "xf86kbdbrightnessup", 0x1008ff05 }, .{ "xf86kbdbrightnessdown", 0x1008ff06 }, .{ "xf86display", 0x1008ff59 },          .{ "xf86search", 0x1008ff1b },
        .{ "xf86launch1", 0x1008ff41 },
    };
    inline for (names) |entry| if (std.ascii.eqlIgnoreCase(token, entry[0])) return entry[1];
    if (token.len >= 2 and token.len <= 3 and (token[0] == 'f' or token[0] == 'F')) {
        const number = std.fmt.parseInt(u8, token[1..], 10) catch 0;
        if (number >= 1 and number <= 24) return 0xffbe + @as(u32, number) - 1;
    }
    if (token.len == 1 and token[0] >= 0x20 and token[0] <= 0x7e) return std.ascii.toLower(token[0]);
    return null;
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) return value[1 .. value.len - 1];
    return value;
}

test "key chord parsing supports modifiers named and media keys" {
    try std.testing.expectEqual(Chord{ .modifiers = 65, .keysym = 'h' }, parseChord("Super+Shift+H").?);
    try std.testing.expectEqual(Chord{ .modifiers = 65, .keysym = '2' }, parseChord("Super+Shift+2").?);
    try std.testing.expectEqual(@as(u32, 0x1008ff13), parseChord("XF86AudioRaiseVolume").?.keysym);
    try std.testing.expectEqual(@as(u32, 0xff61), parseChord("Print").?.keysym);
    try std.testing.expectEqual(parseChord("Print").?, parseChord("PrintScreen").?);
    try std.testing.expectEqual(@as(u32, 0xffe5), parseChord("CapsLock").?.keysym);
    try std.testing.expectEqual(parseChord("CapsLock").?, parseChord("Caps_Lock").?);
    try std.testing.expectEqual(parseChord("CapsLock").?, parseChord("Caps").?);
    try std.testing.expect(parseChord("Super+Shift") == null);
}

test "gesture bindings can be captured, resolved, and replaced" {
    var snapshot: Snapshot = .{};
    addGesture(&snapshot, .swipe, .left, 3, "builtin:focus_workspace_down");

    try std.testing.expect(snapshot.hasGesture(.swipe, 3));
    try std.testing.expect(!snapshot.hasGesture(.pinch, 3));
    try std.testing.expectEqualStrings("builtin:focus_workspace_down", snapshot.findGesture(.swipe, .left, 3).?);
    try std.testing.expect(snapshot.findGesture(.swipe, .right, 3) == null);

    addGesture(&snapshot, .swipe, .left, 3, "builtin:focus_workspace_up");
    try std.testing.expectEqual(@as(u8, 1), snapshot.gestures_count);
    try std.testing.expectEqualStrings("builtin:focus_workspace_up", snapshot.findGesture(.swipe, .left, 3).?);
}

test "shipped defaults keep scrolling output navigation and pointer actions reachable" {
    var snapshot: Snapshot = .{};
    initDefaults(&snapshot);

    const scroll_left = parseChord("Super+Left").?;
    const scroll_right = parseChord("Super+Right").?;
    const scroll_left_legacy = parseChord("Super+Comma").?;
    const scroll_right_legacy = parseChord("Super+Period").?;
    const scroll_up = parseChord("Super+Up").?;
    const scroll_down = parseChord("Super+Down").?;
    const output_left = parseChord("Super+Ctrl+Comma").?;
    const output_right = parseChord("Super+Ctrl+Period").?;
    const previous_workspace = parseChord("Super+BackSpace").?;
    const untrap_pointer = parseChord("Super+grave").?;
    const scrolling_full_width = parseChord("Super+Shift+Z").?;
    const screenshot = parseChord("Print").?;
    const overview = parseChord("Super+W").?;
    const consume_window = parseChord("Super+Ctrl+J").?;
    const expel_window = parseChord("Super+Ctrl+K").?;

    try std.testing.expectEqualStrings("builtin:scroll_viewport_left_arrow", snapshot.find(scroll_left.keysym, scroll_left.modifiers).?);
    try std.testing.expectEqualStrings("builtin:scroll_viewport_right_arrow", snapshot.find(scroll_right.keysym, scroll_right.modifiers).?);
    try std.testing.expectEqualStrings("builtin:scroll_viewport_left", snapshot.find(scroll_left_legacy.keysym, scroll_left_legacy.modifiers).?);
    try std.testing.expectEqualStrings("builtin:scroll_viewport_right", snapshot.find(scroll_right_legacy.keysym, scroll_right_legacy.modifiers).?);
    try std.testing.expectEqualStrings("builtin:scroll_viewport_up", snapshot.find(scroll_up.keysym, scroll_up.modifiers).?);
    try std.testing.expectEqualStrings("builtin:scroll_viewport_down", snapshot.find(scroll_down.keysym, scroll_down.modifiers).?);
    try std.testing.expectEqualStrings("builtin:focus_output_left", snapshot.find(output_left.keysym, output_left.modifiers).?);
    try std.testing.expectEqualStrings("builtin:focus_output_right", snapshot.find(output_right.keysym, output_right.modifiers).?);
    try std.testing.expectEqualStrings("builtin:focus_previous_workspace", snapshot.find(previous_workspace.keysym, previous_workspace.modifiers).?);
    try std.testing.expectEqualStrings("builtin:untrap_pointer", snapshot.find(untrap_pointer.keysym, untrap_pointer.modifiers).?);
    try std.testing.expectEqualStrings("builtin:toggle_scrolling_full_width", snapshot.find(scrolling_full_width.keysym, scrolling_full_width.modifiers).?);
    try std.testing.expectEqualStrings("builtin:consume_window_into_column", snapshot.find(consume_window.keysym, consume_window.modifiers).?);
    try std.testing.expectEqualStrings("builtin:expel_window_from_column", snapshot.find(expel_window.keysym, expel_window.modifiers).?);
    try std.testing.expectEqualStrings("builtin:screenshot", snapshot.find(screenshot.keysym, screenshot.modifiers).?);
    try std.testing.expectEqualStrings("builtin:toggle_overview", snapshot.find(overview.keysym, overview.modifiers).?);
    try std.testing.expectEqualStrings(default_screenshot_command, snapshot.screenshot.slice());
}

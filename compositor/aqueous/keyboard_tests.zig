// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const Keyboard = @import("Keyboard.zig");
const KeyboardGroup = @import("KeyboardGroup.zig");

fn ledUpdate(state: *wlr.Keyboard, leds: u32) callconv(.c) void {
    const last_leds: *u32 = @ptrCast(@alignCast(state.data.?));
    last_leds.* = leds;
}

test "keyboard policy: Num Lock reload preserves modifiers and manual toggles" {
    const context = xkb.Context.new(.no_flags) orelse return error.OutOfMemory;
    defer context.unref();
    const keymap = xkb.Keymap.newFromNames(context, &.{ .rules = null, .model = null, .layout = "us,de", .variant = null, .options = null }, .no_flags) orelse return error.KeymapFailed;
    defer keymap.unref();

    // Exercise the production keyboard/group setters with a real wlroots XKB
    // state. No running compositor or physical input device is required.
    var group: KeyboardGroup = undefined;
    group.virtual = false;
    group.config = .{ .keymap = keymap };
    group.state.init(&.{ .name = "num-lock-test", .led_update = ledUpdate }, "num-lock-test");
    defer group.state.finish();
    var last_leds: u32 = 0;
    group.state.data = &last_leds;
    try std.testing.expect(group.state.setKeymap(keymap));

    var first: Keyboard = undefined;
    first.device.virtual = false;
    first.config = group.config;
    first.group = &group;
    var second: Keyboard = undefined;
    second.device.virtual = false;
    second.config = group.config;
    second.group = &group;

    const num = keymap.modGetMask(xkb.names.vmod.num);
    const caps = keymap.modGetMask(xkb.names.mod.caps);
    const shift = keymap.modGetMask(xkb.names.mod.shift);
    const ctrl = keymap.modGetMask(xkb.names.mod.ctrl);
    const other: wlr.Keyboard.Modifiers = .{ .depressed = shift, .latched = ctrl, .locked = caps, .group = 1 };
    group.state.notifyModifiers(other);
    const caps_leds = last_leds;

    first.setNumLockState(true);
    second.setNumLockState(true);
    try std.testing.expect(first.config.num_lock_state and second.config.num_lock_state);
    try std.testing.expect(group.config.num_lock_state);
    try std.testing.expectEqualDeep(wlr.Keyboard.Modifiers{
        .depressed = shift,
        .latched = ctrl,
        .locked = caps | num,
        .group = 1,
    }, group.state.modifiers);
    try std.testing.expect(last_leds != caps_leds);

    // A manual toggle survives repeated application of the same config, even
    // when multiple physical keyboards share this group.
    group.state.notifyModifiers(other);
    first.setNumLockState(true);
    second.setNumLockState(true);
    try std.testing.expectEqualDeep(other, group.state.modifiers);

    group.state.notifyModifiers(.{ .depressed = shift, .latched = ctrl, .locked = caps | num, .group = 1 });
    first.setNumLockState(false);
    second.setNumLockState(false);
    try std.testing.expect(!first.config.num_lock_state and !second.config.num_lock_state);
    try std.testing.expect(!group.config.num_lock_state);
    try std.testing.expectEqualDeep(other, group.state.modifiers);
    try std.testing.expectEqual(caps_leds, last_leds);

    // Hotplug group matching must include the configured Num Lock policy.
    var matching = group.config;
    try std.testing.expect(group.match(&matching));
    matching.num_lock_state = true;
    try std.testing.expect(!group.match(&matching));
}

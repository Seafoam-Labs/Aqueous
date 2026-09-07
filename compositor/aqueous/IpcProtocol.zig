// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
const Types = @import("ShellCommand.zig");
pub const max_request = 65536;
pub const max_batch = 4194304;
pub const max_frame = max_batch + max_request;
pub const max_depth = 16;
pub const Op = enum { hello, snapshot, subscribe, ack, command };
pub const Request = struct {
    id: []const u8,
    number: u128,
    version: i64,
    session: []const u8,
    op: []const u8,
    params: std.json.ObjectMap,
};

pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Request {
    if (bytes.len > max_request or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidFrame;
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |ch| {
        if (quoted) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') quoted = false;
        } else switch (ch) {
            '"' => quoted = true,
            '{', '[' => {
                depth += 1;
                if (depth > max_depth) return error.InvalidFrame;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidFrame;
                depth -= 1;
            },
            else => {},
        }
    }
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .allocate = .alloc_always });
    if (value != .object) return error.InvalidFrame;
    const obj = value.object;
    const id = try string(obj, "id");
    if (id.len == 0 or id.len > 20) return error.InvalidFrame;
    for (id) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidFrame;
    const version = obj.get("ipc") orelse return error.InvalidFrame;
    if (version != .integer) return error.InvalidFrame;
    const params = obj.get("params") orelse return error.InvalidFrame;
    if (params != .object) return error.InvalidFrame;
    return .{ .id = id, .number = try std.fmt.parseInt(u128, id, 10), .version = version.integer, .session = try optionalString(obj, "session"), .op = try string(obj, "op"), .params = params.object };
}

pub fn string(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = obj.get(key) orelse return error.Invalid;
    if (value != .string or value.string.len > 1024 or std.mem.indexOfScalar(u8, value.string, 0) != null) return error.Invalid;
    return value.string;
}

fn optionalString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return if (obj.contains(key)) try string(obj, key) else "";
}

fn only(obj: std.json.ObjectMap, keys: []const []const u8) !void {
    for (obj.keys()) |key| {
        for (keys) |allowed| {
            if (std.mem.eql(u8, key, allowed)) break;
        } else return error.Invalid;
    }
}

pub fn command(a: std.mem.Allocator, params: std.json.ObjectMap) !Types.Command {
    try only(params, &.{ "action", "fields" });
    const action = try string(params, "action");
    const f = params.get("fields") orelse return error.Invalid;
    if (f != .object) return error.Invalid;
    const fields = f.object;
    const mappings = .{
        .{ "window.activate", Types.Action.window_activate },       .{ "window.close", Types.Action.window_close },
        .{ "window.minimized", Types.Action.window_minimized },     .{ "window.maximized", Types.Action.window_maximized },
        .{ "window.fullscreen", Types.Action.window_fullscreen },   .{ "window.move", Types.Action.window_move_workspace },
        .{ "workspace.activate", Types.Action.workspace_activate }, .{ "workspace.rename", Types.Action.workspace_rename },
        .{ "keyboard.set", Types.Action.keyboard_set },             .{ "keyboard.next", Types.Action.keyboard_next },
        .{ "overview.show", Types.Action.overview_show },           .{ "overview.hide", Types.Action.overview_hide },
        .{ "overview.toggle", Types.Action.overview_toggle },       .{ "session.exit", Types.Action.session_exit },
    };
    const selected: Types.Action = blk: {
        inline for (mappings) |mapping| if (std.mem.eql(u8, action, mapping[0])) break :blk mapping[1];
        return error.Unsupported;
    };
    var cmd: Types.Command = .{ .action = selected, .output_by_id = true };
    switch (selected) {
        .window_activate, .workspace_activate => {
            try only(fields, &.{ "id", "seat" });
            cmd.target = try string(fields, "id");
            cmd.seat = try optionalString(fields, "seat");
        },
        .window_close => {
            try only(fields, &.{"id"});
            cmd.target = try string(fields, "id");
        },
        .window_minimized, .window_maximized, .window_fullscreen => {
            try only(fields, &.{ "id", "value" });
            cmd.target = try string(fields, "id");
            const value = fields.get("value") orelse return error.Invalid;
            if (value != .bool) return error.Invalid;
            cmd.value = if (value.bool) "true" else "false";
        },
        .window_move_workspace => {
            try only(fields, &.{ "id", "workspace", "output" });
            cmd.target = try string(fields, "id");
            if (fields.contains("workspace") == fields.contains("output")) return error.Invalid;
            if (fields.contains("output")) {
                cmd.action = .window_move_output;
                cmd.value = try string(fields, "output");
            } else cmd.value = try string(fields, "workspace");
        },
        .workspace_rename => {
            try only(fields, &.{ "id", "name" });
            cmd.target = try string(fields, "id");
            cmd.value = try string(fields, "name");
            if (std.mem.indexOfAny(u8, cmd.value, "\r\n") != null) return error.Invalid;
        },
        .keyboard_set, .keyboard_next => {
            try only(fields, if (selected == .keyboard_set) &.{ "seat", "group", "index" } else &.{ "seat", "group" });
            cmd.seat = try optionalString(fields, "seat");
            cmd.target = try optionalString(fields, "group");
            if (selected == .keyboard_set) {
                const index = fields.get("index") orelse return error.Invalid;
                if (index != .integer or index.integer < 0 or index.integer > std.math.maxInt(u32)) return error.Invalid;
                cmd.value = try std.fmt.allocPrint(a, "{d}", .{index.integer});
            }
        },
        .overview_show, .overview_toggle => {
            try only(fields, &.{"output"});
            cmd.value = try string(fields, "output");
        },
        .overview_hide, .session_exit => try only(fields, &.{}),
        .window_move_output => unreachable,
    }
    return cmd;
}

pub fn peerAllowed(query_succeeded: bool, peer_uid: u32, own_uid: u32) bool {
    return query_succeeded and peer_uid == own_uid;
}

test "bounded parsing and credential failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request = try parse(a, "{\"ipc\":1,\"id\":\"18446744073709551616\",\"op\":\"hello\",\"params\":{}}");
    try std.testing.expectEqual(@as(u128, 18446744073709551616), request.number);
    try std.testing.expectError(error.InvalidFrame, parse(a, "{\"ipc\":1,\"id\":\"-1\",\"op\":\"hello\",\"params\":{}}"));
    try std.testing.expectError(error.InvalidFrame, parse(a, "[[[[[[[[[[[[[[[[[0]]]]]]]]]]]]]]]]]"));
    try std.testing.expectError(error.InvalidFrame, parse(a, "\xff"));
    try std.testing.expect(!peerAllowed(false, 1000, 1000));
    try std.testing.expect(!peerAllowed(true, 1001, 1000));
    try std.testing.expect(peerAllowed(true, 1000, 1000));
}

test "typed command conversion rejects ambiguous moves and nonboolean state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"action\":\"window.move\",\"fields\":{\"id\":\"w\",\"output\":\"2\"}}", .{});
    const cmd = try command(a, good.object);
    try std.testing.expectEqual(Types.Action.window_move_output, cmd.action);
    try std.testing.expect(cmd.output_by_id);
    for ([_][]const u8{
        "{\"action\":\"window.move\",\"fields\":{\"id\":\"w\",\"output\":\"2\",\"workspace\":\"3\"}}",
        "{\"action\":\"window.fullscreen\",\"fields\":{\"id\":\"w\",\"value\":\"true\"}}",
        "{\"action\":\"session.exit\",\"fields\":{\"extra\":true}}",
    }) |bytes| {
        const bad = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
        try std.testing.expectError(error.Invalid, command(a, bad.object));
    }
}

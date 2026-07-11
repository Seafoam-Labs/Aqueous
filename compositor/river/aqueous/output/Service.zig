// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const Service = @This();
const std = @import("std");
const wl = @import("wayland").server.wl;
const linux = std.os.linux;
const util = @import("../../util.zig");
const Output = @import("../../Output.zig");
const OutputManager = @import("../../OutputManager.zig");
const Config = @import("config.zig");

const server = &@import("../../main.zig").server;
const log = std.log.scoped(.output_service);
const max_clients = 16;
const max_request = 64 * 1024;
const max_response = 256 * 1024;
const max_config_bytes = 1024 * 1024;

listen_fd: i32 = -1,
listen_source: ?*wl.EventSource = null,
clients: [max_clients]Client = undefined,
socket_path: [std.fs.max_path_bytes]u8 = undefined,
socket_path_len: usize = 0,
config: Config.Snapshot = .{},
persisted: Config.Snapshot = .{},
active_profile: Config.Text = .{},
known_outputs: [Config.max_outputs]Config.Text = undefined,
known_output_count: u8 = 0,
output_fingerprint: u64 = 0,
wm_fingerprint: u64 = 0,
persisted_fingerprint: u64 = 0,
started: bool = false,

const Client = struct {
    service: *Service,
    fd: i32 = -1,
    source: ?*wl.EventSource = null,
    input: [max_request]u8 = undefined,
    input_len: usize = 0,
    subscribed: bool = false,
};

pub fn init(service: *Service) void {
    service.* = .{};
    for (&service.clients) |*client| client.* = .{ .service = service };
}

pub fn start(service: *Service) void {
    if (service.started) return;
    service.reload(false);
    if (service.config.apply_on_start) service.applyConfigured();
    service.openSocket() catch |err| {
        log.warn("unable to create output compatibility socket: {}", .{err});
        return;
    };
    service.captureOutputNames();
    service.output_fingerprint = outputFingerprint();
    service.started = true;
}

pub fn deinit(service: *Service) void {
    for (&service.clients) |*client| service.closeClient(client);
    if (service.listen_source) |source| source.remove();
    service.listen_source = null;
    if (service.listen_fd >= 0) _ = linux.close(service.listen_fd);
    service.listen_fd = -1;
    if (service.socket_path_len != 0) {
        service.socket_path[service.socket_path_len] = 0;
        _ = linux.unlink(@ptrCast(&service.socket_path));
    }
    service.started = false;
}

pub fn reload(service: *Service, apply: bool) void {
    service.config = loadWmConfig();
    service.persisted = loadOutputsConfig();
    service.wm_fingerprint = configFingerprint(true);
    service.persisted_fingerprint = configFingerprint(false);
    if (apply and service.config.apply_on_reload) service.applyConfigured();
}

pub fn pollReload(service: *Service) bool {
    const wm_fingerprint = configFingerprint(true);
    const persisted_fingerprint = configFingerprint(false);
    if (wm_fingerprint == service.wm_fingerprint and persisted_fingerprint == service.persisted_fingerprint) return false;
    service.reload(true);
    log.info("output configuration hot-reloaded", .{});
    return true;
}

fn applyConfigured(service: *Service) void {
    var selected: [Config.max_outputs]Config.Spec = undefined;
    var count: usize = 0;
    for (service.config.outputs[0..service.config.output_count]) |entry| if (entry.hasDisplayField()) {
        selected[count] = entry;
        count += 1;
    };
    if (count == 0) {
        for (service.persisted.outputs[0..service.persisted.output_count]) |entry| {
            selected[count] = entry;
            count += 1;
        }
    }
    if (count == 0) return;
    const applied = server.om.applySpecs(selected[0..count]) catch |err| {
        log.warn("configured output transaction rejected: {}", .{err});
        if (!service.config.fallback_profile.empty()) _ = service.applyProfile(service.config.fallback_profile.slice()) catch 0;
        return;
    };
    log.info("staged native output configuration for {d} output(s)", .{applied});
}

fn applyProfile(service: *Service, name: []const u8) !usize {
    const profile = service.config.profile(name) orelse service.persisted.profile(name) orelse return error.UnknownProfile;
    const applied = try server.om.applySpecs(profile.outputs[0..profile.output_count]);
    _ = service.active_profile.set(name);
    service.broadcastProfileChanged();
    return applied;
}

pub fn outputsChanged(service: *Service, hotplug: bool) void {
    if (!service.started) return;
    if (hotplug) {
        service.broadcastHotplug();
        service.captureOutputNames();
        service.applyConfigured();
    }
    const fingerprint = outputFingerprint();
    if (!hotplug and fingerprint == service.output_fingerprint) return;
    service.output_fingerprint = fingerprint;
    service.broadcastOutputChanged();
}

fn openSocket(service: *Service) !void {
    const runtime = getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&directory, "{s}/aqueous", .{runtime});
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    const path = try std.fmt.bufPrint(&service.socket_path, "{s}/outputd.sock", .{dir_path});
    service.socket_path_len = path.len;
    service.socket_path[path.len] = 0;
    _ = linux.unlink(@ptrCast(&service.socket_path));

    const socket_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket_rc) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(socket_rc);
    errdefer _ = linux.close(fd);
    var address: linux.sockaddr.un = .{ .path = [_]u8{0} ** 108 };
    if (path.len >= address.path.len) return error.NameTooLong;
    @memcpy(address.path[0..path.len], path);
    const bind_rc = linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un));
    if (linux.errno(bind_rc) != .SUCCESS) return error.BindFailed;
    if (linux.errno(linux.listen(fd, max_clients)) != .SUCCESS) return error.ListenFailed;
    _ = linux.chmod(@ptrCast(&service.socket_path), 0o600);
    service.listen_fd = fd;
    service.listen_source = try server.wl_server.getEventLoop().addFd(*Service, fd, .{ .readable = true }, handleAccept, service);
    log.info("output protocol=1 listening on {s}", .{path});
}

fn handleAccept(_: c_int, mask: wl.EventMask, service: *Service) c_int {
    if (mask.hangup or mask.@"error") return 0;
    while (true) {
        const rc = linux.accept4(service.listen_fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return 0,
            else => return 0,
        }
        const fd: i32 = @intCast(rc);
        if (!sameUid(fd)) {
            _ = linux.close(fd);
            continue;
        }
        const client = service.freeClient() orelse {
            _ = linux.close(fd);
            continue;
        };
        client.fd = fd;
        client.source = server.wl_server.getEventLoop().addFd(*Client, fd, .{ .readable = true }, handleClient, client) catch {
            service.closeClient(client);
            continue;
        };
    }
}

fn handleClient(fd: c_int, mask: wl.EventMask, client: *Client) c_int {
    if (mask.hangup or mask.@"error") {
        client.service.closeClient(client);
        return 0;
    }
    var temp: [8192]u8 = undefined;
    var peer_closed = false;
    while (true) {
        const rc = linux.recvfrom(fd, &temp, temp.len, 0, null, null);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => break,
            else => {
                client.service.closeClient(client);
                return 0;
            },
        }
        if (rc == 0) {
            peer_closed = true;
            break;
        }
        const amount: usize = rc;
        if (client.input_len + amount > client.input.len) {
            client.service.sendError(client, "request too large");
            client.service.closeClient(client);
            return 0;
        }
        @memcpy(client.input[client.input_len .. client.input_len + amount], temp[0..amount]);
        client.input_len += amount;
    }
    while (std.mem.indexOfScalar(u8, client.input[0..client.input_len], '\n')) |newline| {
        const line = std.mem.trim(u8, client.input[0..newline], "\r \t");
        if (line.len != 0) client.service.handleRequest(client, line);
        const consumed = newline + 1;
        std.mem.copyForwards(u8, client.input[0 .. client.input_len - consumed], client.input[consumed..client.input_len]);
        client.input_len -= consumed;
        if (client.fd < 0) return 0;
    }
    if (peer_closed and client.input_len != 0) {
        const line = std.mem.trim(u8, client.input[0..client.input_len], "\r \t");
        if (line.len != 0) client.service.handleRequest(client, line);
        client.input_len = 0;
    }
    if (peer_closed) client.service.closeClient(client);
    return 0;
}

fn handleRequest(service: *Service, client: *Client, line: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, util.gpa, line, .{}) catch {
        service.sendError(client, "bad json");
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return service.sendError(client, "expected object");
    const op_value = parsed.value.object.get("op") orelse return service.sendError(client, "unknown op ''");
    if (op_value != .string) return service.sendError(client, "op must be a string");
    const op = op_value.string;
    if (std.mem.eql(u8, op, "version")) return service.sendStatic(client, "{\"ok\":true,\"daemon\":\"aqueous-outputd\",\"version\":\"0.0.1\",\"protocol\":1}\n");
    if (std.mem.eql(u8, op, "list")) return service.sendList(client, true, null);
    if (std.mem.eql(u8, op, "reload")) {
        service.reload(true);
        service.broadcastOutputChanged();
        return service.sendStatic(client, "{\"ok\":true}\n");
    }
    if (std.mem.eql(u8, op, "subscribe")) {
        client.subscribed = true;
        return service.sendStatic(client, "{\"ok\":true,\"subscribed\":true}\n");
    }
    if (std.mem.eql(u8, op, "apply_profile")) {
        const name = jsonString(parsed.value.object.get("name")) orelse return service.sendError(client, "missing 'name'");
        const applied = service.applyProfile(name) catch return service.sendError(client, "unknown profile");
        return service.sendList(client, true, applied);
    }
    if (std.mem.eql(u8, op, "set")) return service.handleSet(client, parsed.value.object.get("changes"));
    if (std.mem.eql(u8, op, "save_profile")) return service.handleSaveProfile(client, &parsed.value);
    service.sendError(client, "unknown op");
}

fn handleSet(service: *Service, client: *Client, changes_value: ?std.json.Value) void {
    const changes = changes_value orelse return service.sendError(client, "missing 'changes' array");
    if (changes != .array) return service.sendError(client, "missing 'changes' array");
    var specs: [Config.max_outputs]Config.Spec = undefined;
    var count: usize = 0;
    for (changes.array.items) |value| {
        if (count == specs.len or value != .object) return service.sendError(client, "change must be an object");
        specs[count] = specFromJson(value.object) orelse return service.sendError(client, "invalid change");
        count += 1;
    }
    const applied = server.om.applySpecs(specs[0..count]) catch |err| return service.sendApplyError(client, err);
    service.broadcastOutputChanged();
    service.sendList(client, true, applied);
}

fn specFromJson(object: std.json.ObjectMap) ?Config.Spec {
    var spec: Config.Spec = .{};
    if (jsonString(object.get("name"))) |value| if (!spec.name.set(value)) return null;
    if (jsonString(object.get("edid"))) |value| if (!spec.edid.set(value)) return null;
    spec.enabled = jsonBool(object.get("enabled"));
    if (jsonString(object.get("mode"))) |value| spec.mode = Config.parseMode(value) orelse return null;
    if (jsonNumber(object.get("scale"))) |value| {
        if (!std.math.isFinite(value) or value < 0.5 or value > 3.0) return null;
        spec.scale = @floatCast(value);
    }
    if (jsonString(object.get("transform"))) |value| spec.transform = Config.parseTransform(value) orelse return null;
    if (object.get("position")) |position| {
        if (position != .array or position.array.items.len != 2) return null;
        spec.x = jsonInt(position.array.items[0]) orelse return null;
        spec.y = jsonInt(position.array.items[1]) orelse return null;
    }
    spec.adaptive_sync = jsonBool(object.get("adaptive_sync"));
    if (spec.name.empty() and spec.edid.empty()) return null;
    return spec;
}

fn handleSaveProfile(service: *Service, client: *Client, request: *const std.json.Value) void {
    const name = jsonString(request.object.get("name")) orelse return service.sendError(client, "missing 'name'");
    const outputs = request.object.get("outputs") orelse return service.sendError(client, "missing 'outputs' array");
    if (outputs != .array) return service.sendError(client, "missing 'outputs' array");
    service.persistProfile(name, outputs.array.items) catch return service.sendError(client, "write failed");
    service.reload(false);
    var response: [std.fs.max_path_bytes + 64]u8 = undefined;
    const path = outputsPath(&response) orelse return service.sendError(client, "write failed");
    var buffer: [std.fs.max_path_bytes + 80]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var json: std.json.Stringify = .{ .writer = &writer };
    json.beginObject() catch return service.sendError(client, "write failed");
    field(&json, "ok", true) catch return service.sendError(client, "write failed");
    field(&json, "path", path) catch return service.sendError(client, "write failed");
    json.endObject() catch return service.sendError(client, "write failed");
    writer.writeByte('\n') catch return service.sendError(client, "write failed");
    service.sendStatic(client, writer.buffered());
}

fn persistProfile(_: *Service, name: []const u8, outputs: []const std.json.Value) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = outputsPath(&path_buffer) orelse return error.NoHome;
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = std.fs.path.dirname(path) orelse return error.NoHome;
    @memcpy(dir_buffer[0..directory.len], directory);
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const existing = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, util.gpa, .limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => try util.gpa.dupe(u8, ""),
        else => return err,
    };
    defer util.gpa.free(existing);
    var content: [max_config_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&content);
    try writer.writeAll(existing);
    try writer.writeAll("\n[[display.profile]]\nname = ");
    try writeTomlString(&writer, name);
    try writer.writeByte('\n');
    for (outputs) |value| {
        if (value != .object) continue;
        const spec = specFromJson(value.object) orelse continue;
        try writer.writeAll("\n[[display.profile.output]]\n");
        if (!spec.edid.empty()) {
            try writer.writeAll("edid = ");
            try writeTomlString(&writer, spec.edid.slice());
        } else {
            try writer.writeAll("name = ");
            try writeTomlString(&writer, spec.name.slice());
        }
        try writer.writeByte('\n');
        if (spec.enabled) |v| try writer.print("enabled = {}\n", .{v});
        if (spec.mode) |v| if (v.refresh_mhz) |refresh| try writer.print("mode = \"{d}x{d}@{d}.{d:0>3}\"\n", .{ v.width, v.height, @divTrunc(refresh, 1000), @mod(refresh, 1000) }) else try writer.print("mode = \"{d}x{d}\"\n", .{ v.width, v.height });
        if (spec.scale) |v| try writer.print("scale = {d}\n", .{v});
        if (spec.transform) |v| try writer.print("transform = \"{s}\"\n", .{configTransformName(v)});
        if (spec.x) |x| try writer.print("position = [{d}, {d}]\n", .{ x, spec.y.? });
        if (spec.adaptive_sync) |v| try writer.print("adaptive_sync = {}\n", .{v});
    }
    var tmp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buffer, "{s}.tmp", .{path});
    var file = try std.Io.Dir.createFileAbsolute(io, tmp, .{ .truncate = true });
    defer file.close(io);
    var file_buffer: [8192]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    try file_writer.interface.writeAll(writer.buffered());
    try file_writer.interface.flush();
    try std.Io.Dir.renameAbsolute(tmp, path, io);
}

fn writeTomlString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn sendList(service: *Service, client: *Client, ok: bool, applied: ?usize) void {
    var buffer: [max_response]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var json: std.json.Stringify = .{ .writer = &writer };
    json.beginObject() catch return;
    json.objectField("ok") catch return;
    json.write(ok) catch return;
    if (applied) |count| {
        json.objectField("applied") catch return;
        json.write(count) catch return;
    }
    json.objectField("outputs") catch return;
    service.writeOutputs(&json) catch return;
    json.endObject() catch return;
    writer.writeByte('\n') catch return;
    service.sendStatic(client, writer.buffered());
}

fn writeOutputs(_: *Service, json: *std.json.Stringify) !void {
    try json.beginArray();
    var it = server.om.outputs.iterator(.forward);
    while (it.next()) |output| {
        const wlr_output = output.wlr_output orelse continue;
        const state = output.scheduled;
        try json.beginObject();
        try field(json, "name", std.mem.span(wlr_output.name));
        try optionalField(json, "make", wlr_output.make);
        try optionalField(json, "model", wlr_output.model);
        try optionalField(json, "serial", wlr_output.serial);
        var hash_buffer: [71]u8 = undefined;
        try json.objectField("edid_sha256");
        if (identityHash(wlr_output, &hash_buffer)) |hash| try json.write(hash) else try json.write(null);
        try field(json, "enabled", state.state == .enabled);
        try field(json, "x", state.x);
        try field(json, "y", state.y);
        try field(json, "scale", state.scale);
        try field(json, "transform", OutputManager.transformName(state.transform));
        try field(json, "adaptive_sync", state.adaptive_sync);
        try json.objectField("current_mode");
        try writeModeState(json, state);
        try json.objectField("modes");
        try json.beginArray();
        var modes = wlr_output.modes.iterator(.forward);
        while (modes.next()) |mode| {
            try json.beginObject();
            try field(json, "width", mode.width);
            try field(json, "height", mode.height);
            try field(json, "refresh", @as(f64, @floatFromInt(mode.refresh)) / 1000.0);
            try field(json, "preferred", mode.preferred);
            try field(json, "current", switch (state.mode) {
                .standard => |current| current == mode,
                else => false,
            });
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
}

fn writeModeState(json: *std.json.Stringify, state: Output.State) !void {
    const mode = switch (state.mode) {
        .standard => |value| .{ value.width, value.height, value.refresh },
        .custom => |value| .{ value.width, value.height, value.refresh },
        .none => return json.write(null),
    };
    try json.beginObject();
    try field(json, "width", mode[0]);
    try field(json, "height", mode[1]);
    try field(json, "refresh", @as(f64, @floatFromInt(mode[2])) / 1000.0);
    try json.endObject();
}

fn field(json: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

fn optionalField(json: *std.json.Stringify, name: []const u8, value: ?[*:0]u8) !void {
    try json.objectField(name);
    if (value) |text| try json.write(std.mem.span(text)) else try json.write(null);
}

fn sendApplyError(service: *Service, client: *Client, err: OutputManager.ApplyError) void {
    service.sendError(client, switch (err) {
        error.MissingMatcher => "missing 'name' or 'edid'",
        error.UnknownOutput => "unknown output or no valid wildcard matches",
        error.WildcardPosition => "position not allowed with wildcard name",
        error.ModeNotAdvertised => "mode not in availableModes",
        error.InvalidCoordinates => "coordinates are incompatible with Xwayland",
        error.TooManyOutputs => "too many outputs",
    });
}

fn sendError(service: *Service, client: *Client, message: []const u8) void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var json: std.json.Stringify = .{ .writer = &writer };
    json.beginObject() catch return;
    field(&json, "ok", false) catch return;
    field(&json, "error", message) catch return;
    json.endObject() catch return;
    writer.writeByte('\n') catch return;
    service.sendStatic(client, writer.buffered());
}

fn sendStatic(_: *Service, client: *Client, message: []const u8) void {
    var sent: usize = 0;
    while (sent < message.len) {
        const rc = linux.sendto(client.fd, message[sent..].ptr, message.len - sent, linux.MSG.NOSIGNAL, null, 0);
        if (linux.errno(rc) != .SUCCESS) return;
        sent += rc;
    }
}

fn broadcastOutputChanged(service: *Service) void {
    var buffer: [max_response]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var json: std.json.Stringify = .{ .writer = &writer };
    json.beginObject() catch return;
    field(&json, "event", "output-changed") catch return;
    json.objectField("data") catch return;
    json.beginObject() catch return;
    json.objectField("outputs") catch return;
    service.writeOutputs(&json) catch return;
    json.endObject() catch return;
    json.endObject() catch return;
    writer.writeByte('\n') catch return;
    service.broadcast(writer.buffered());
}

fn broadcastHotplug(service: *Service) void {
    var current: [Config.max_outputs]Config.Text = undefined;
    const current_count = collectOutputNames(&current);
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var json: std.json.Stringify = .{ .writer = &writer };
    json.beginObject() catch return;
    field(&json, "event", "hotplug") catch return;
    json.objectField("data") catch return;
    json.beginObject() catch return;
    json.objectField("added") catch return;
    json.beginArray() catch return;
    for (current[0..current_count]) |*name| if (!containsName(service.known_outputs[0..service.known_output_count], name.slice())) json.write(name.slice()) catch return;
    json.endArray() catch return;
    json.objectField("removed") catch return;
    json.beginArray() catch return;
    for (service.known_outputs[0..service.known_output_count]) |*name| if (!containsName(current[0..current_count], name.slice())) json.write(name.slice()) catch return;
    json.endArray() catch return;
    json.endObject() catch return;
    json.endObject() catch return;
    writer.writeByte('\n') catch return;
    service.broadcast(writer.buffered());
}

fn broadcastProfileChanged(service: *Service) void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var json: std.json.Stringify = .{ .writer = &writer };
    json.beginObject() catch return;
    field(&json, "event", "profile-changed") catch return;
    json.objectField("data") catch return;
    json.beginObject() catch return;
    field(&json, "name", service.active_profile.slice()) catch return;
    json.endObject() catch return;
    json.endObject() catch return;
    writer.writeByte('\n') catch return;
    service.broadcast(writer.buffered());
}

fn broadcast(service: *Service, message: []const u8) void {
    for (&service.clients) |*client| if (client.fd >= 0 and client.subscribed) service.sendStatic(client, message);
}

fn freeClient(service: *Service) ?*Client {
    for (&service.clients) |*client| if (client.fd < 0) return client;
    return null;
}

fn captureOutputNames(service: *Service) void {
    service.known_output_count = collectOutputNames(&service.known_outputs);
}

fn collectOutputNames(names: *[Config.max_outputs]Config.Text) u8 {
    var count: u8 = 0;
    var it = server.om.outputs.iterator(.forward);
    while (it.next()) |output| {
        const wlr_output = output.wlr_output orelse continue;
        if (count == names.len) break;
        names[count] = .{};
        if (names[count].set(std.mem.span(wlr_output.name))) count += 1;
    }
    return count;
}

fn containsName(names: []const Config.Text, wanted: []const u8) bool {
    for (names) |*name| if (std.mem.eql(u8, name.slice(), wanted)) return true;
    return false;
}

fn outputFingerprint() u64 {
    var hash = std.hash.Wyhash.init(0);
    var it = server.om.outputs.iterator(.forward);
    while (it.next()) |output| {
        const wlr_output = output.wlr_output orelse continue;
        hash.update(std.mem.span(wlr_output.name));
        const state = output.scheduled;
        const enabled: u8 = if (state.state == .enabled) 1 else 0;
        hash.update(std.mem.asBytes(&enabled));
        hash.update(std.mem.asBytes(&state.x));
        hash.update(std.mem.asBytes(&state.y));
        hash.update(std.mem.asBytes(&state.scale));
        const transform: c_int = @intFromEnum(state.transform);
        hash.update(std.mem.asBytes(&transform));
        hash.update(std.mem.asBytes(&state.adaptive_sync));
        switch (state.mode) {
            .standard => |mode| {
                hash.update(std.mem.asBytes(&mode.width));
                hash.update(std.mem.asBytes(&mode.height));
                hash.update(std.mem.asBytes(&mode.refresh));
            },
            .custom => |mode| {
                hash.update(std.mem.asBytes(&mode.width));
                hash.update(std.mem.asBytes(&mode.height));
                hash.update(std.mem.asBytes(&mode.refresh));
            },
            .none => {},
        }
    }
    return hash.final();
}

fn closeClient(_: *Service, client: *Client) void {
    if (client.source) |source| source.remove();
    client.source = null;
    if (client.fd >= 0) _ = linux.close(client.fd);
    client.fd = -1;
    client.input_len = 0;
    client.subscribed = false;
}

fn sameUid(fd: i32) bool {
    const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };
    var cred: Ucred = undefined;
    var len: linux.socklen_t = @sizeOf(Ucred);
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, @ptrCast(&cred), &len);
    return linux.errno(rc) != .SUCCESS or cred.uid == linux.getuid();
}

fn loadWmConfig() Config.Snapshot {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = wmPath(&buffer) orelse return .{};
    return loadPath(path);
}

fn loadOutputsConfig() Config.Snapshot {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = outputsPath(&buffer) orelse return .{};
    return loadPath(path);
}

fn loadPath(path: []const u8) Config.Snapshot {
    const io = std.Io.Threaded.global_single_threaded.io();
    const source = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, util.gpa, .limited(max_config_bytes)) catch return .{};
    defer util.gpa.free(source);
    return Config.parse(source);
}

fn configFingerprint(wm_config: bool) u64 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = (if (wm_config) wmPath(&buffer) else outputsPath(&buffer)) orelse return 0;
    const io = std.Io.Threaded.global_single_threaded.io();
    const source = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, util.gpa, .limited(max_config_bytes)) catch return 0;
    defer util.gpa.free(source);
    return std.hash.Wyhash.hash(0, source);
}

fn wmPath(buffer: []u8) ?[]const u8 {
    if (getenv("AQUEOUS_CONFIG")) |path| return std.fmt.bufPrint(buffer, "{s}", .{path}) catch null;
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        const candidate = std.fmt.bufPrint(buffer, "{s}/aqueous/wm.toml", .{xdg}) catch return null;
        if (pathExists(candidate)) return candidate;
    }
    if (getenv("HOME")) |home| {
        const candidate = std.fmt.bufPrint(buffer, "{s}/.config/aqueous/wm.toml", .{home}) catch return null;
        if (pathExists(candidate)) return candidate;
    }
    return if (pathExists("/etc/xdg/aqueous/wm.toml")) std.fmt.bufPrint(buffer, "/etc/xdg/aqueous/wm.toml", .{}) catch null else null;
}

fn outputsPath(buffer: []u8) ?[]const u8 {
    if (getenv("XDG_CONFIG_HOME")) |xdg| return std.fmt.bufPrint(buffer, "{s}/aqueous/outputs.toml", .{xdg}) catch null;
    if (getenv("HOME")) |home| return std.fmt.bufPrint(buffer, "{s}/.config/aqueous/outputs.toml", .{home}) catch null;
    return null;
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |value| std.mem.span(value) else null;
}

fn pathExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const actual = value orelse return null;
    return if (actual == .string) actual.string else null;
}

fn jsonBool(value: ?std.json.Value) ?bool {
    const actual = value orelse return null;
    return if (actual == .bool) actual.bool else null;
}

fn jsonNumber(value: ?std.json.Value) ?f64 {
    const actual = value orelse return null;
    return switch (actual) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        else => null,
    };
}

fn jsonInt(value: std.json.Value) ?i32 {
    return switch (value) {
        .integer => |v| std.math.cast(i32, v),
        .float => |v| if (std.math.isFinite(v) and @floor(v) == v and v >= std.math.minInt(i32) and v <= std.math.maxInt(i32)) @intFromFloat(v) else null,
        else => null,
    };
}

fn configTransformName(value: Config.Transform) []const u8 {
    return switch (value) {
        .normal => "normal",
        .rotate_90 => "90",
        .rotate_180 => "180",
        .rotate_270 => "270",
        .flipped => "flipped",
        .flipped_90 => "flipped-90",
        .flipped_180 => "flipped-180",
        .flipped_270 => "flipped-270",
    };
}

fn identityHash(output: *const @import("wlroots").Output, buffer: *[71]u8) ?[]const u8 {
    if (output.make == null and output.model == null and output.serial == null) return null;
    var identity: [768]u8 = undefined;
    const source = std.fmt.bufPrint(&identity, "{s}|{s}|{s}", .{ if (output.make) |v| std.mem.span(v) else "", if (output.model) |v| std.mem.span(v) else "", if (output.serial) |v| std.mem.span(v) else "" }) catch return null;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.bufPrint(buffer, "sha256:{s}", .{hex}) catch null;
}

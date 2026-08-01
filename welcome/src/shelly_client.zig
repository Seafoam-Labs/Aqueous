const std = @import("std");
const catalog = @import("catalog.zig");
const registry = @import("sections.zig");
const protocol = @import("shelly_protocol.zig");

pub const Installed = [registry.application_count]bool;

const Package = struct {
    Name: []const u8 = "",
};

const Flatpak = struct {
    Id: []const u8 = "",
    Kind: i64 = 0,
};

pub const ProgressCallback = struct {
    context: *anyopaque,
    function: *const fn (*anyopaque, protocol.Progress) void,

    pub fn call(self: ProgressCallback, progress: protocol.Progress) void {
        self.function(self.context, progress);
    }
};

pub fn isAvailable(
    allocator: std.mem.Allocator,
    io: std.Io,
    shelly_path: []const u8,
) bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ shelly_path, "--version" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return succeeded(result.term);
}

pub fn discoverInstalled(
    allocator: std.mem.Allocator,
    io: std.Io,
    shelly_path: []const u8,
    installed: *Installed,
) !void {
    installed.* = @splat(false);
    var successful_queries: usize = 0;
    if (queryPackages(allocator, io, shelly_path, .standard)) |packages| {
        defer packages.deinit();
        markPackages(installed, .standard, packages.value);
        successful_queries += 1;
    } else |_| {}
    if (queryPackages(allocator, io, shelly_path, .aur)) |packages| {
        defer packages.deinit();
        markPackages(installed, .aur, packages.value);
        successful_queries += 1;
    } else |_| {}
    if (queryFlatpaks(allocator, io, shelly_path)) |flatpaks| {
        defer flatpaks.deinit();
        markFlatpaks(installed, flatpaks.value);
        successful_queries += 1;
    } else |_| {}
    if (successful_queries == 0) return error.DiscoveryFailed;
}

fn queryPackages(
    allocator: std.mem.Allocator,
    io: std.Io,
    shelly_path: []const u8,
    backend: catalog.Backend,
) !std.json.Parsed([]Package) {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ shelly_path, "list", @tagName(backend), "--json" },
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!succeeded(result.term)) return error.CommandFailed;
    return std.json.parseFromSlice([]Package, allocator, result.stdout, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

fn queryFlatpaks(
    allocator: std.mem.Allocator,
    io: std.Io,
    shelly_path: []const u8,
) !std.json.Parsed([]Flatpak) {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ shelly_path, "list", "flatpak", "--json" },
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!succeeded(result.term)) return error.CommandFailed;
    return std.json.parseFromSlice([]Flatpak, allocator, result.stdout, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

fn markPackages(installed: *Installed, backend: catalog.Backend, packages: []const Package) void {
    for (0..registry.application_count) |index| {
        const application = registry.applicationAt(index).?;
        if (application.package.backend != backend) continue;
        for (packages) |package| {
            if (std.mem.eql(u8, package.Name, application.package.name)) {
                installed[index] = true;
                break;
            }
        }
    }
}

fn markFlatpaks(installed: *Installed, flatpaks: []const Flatpak) void {
    for (0..registry.application_count) |index| {
        const application = registry.applicationAt(index).?;
        if (application.package.backend != .flatpak) continue;
        for (flatpaks) |flatpak| {
            if (flatpak.Kind == 0 and std.mem.eql(u8, flatpak.Id, application.package.name)) {
                installed[index] = true;
                break;
            }
        }
    }
}

pub fn runInstall(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    callback: ProgressCallback,
) !bool {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    const stdout = child.stdout orelse return error.NoStdout;

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var read_buffer: [8192]u8 = undefined;
    while (true) {
        const count = stdout.readStreaming(io, &.{&read_buffer}) catch break;
        if (count == 0) break;
        try pending.appendSlice(allocator, read_buffer[0..count]);

        while (protocol.Frame.next(pending.items)) |frame| {
            const json = protocol.Frame.decode(allocator, frame.payload) catch {
                consume(&pending, frame.consumed);
                continue;
            };
            defer allocator.free(json);
            const progress = protocol.progressFromJson(allocator, json) catch {
                consume(&pending, frame.consumed);
                continue;
            };
            callback.call(progress);
            consume(&pending, frame.consumed);
        }

        // Shelly UI output is framed. Bound unframed diagnostics so a malformed
        // child cannot grow the setup process without limit.
        if (pending.items.len > 1024 * 1024) pending.clearRetainingCapacity();
    }

    return succeeded((try child.wait(io)));
}

fn consume(buffer: *std.ArrayList(u8), count: usize) void {
    const remaining = buffer.items.len - count;
    std.mem.copyForwards(u8, buffer.items[0..remaining], buffer.items[count..]);
    buffer.shrinkRetainingCapacity(remaining);
}

fn succeeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "installed package matching is backend-specific" {
    var installed: Installed = @splat(false);
    markPackages(&installed, .standard, &.{.{ .Name = "firefox" }});
    try std.testing.expect(installed[0]);
    try std.testing.expect(!installed[1]);

    markFlatpaks(&installed, &.{.{ .Id = "org.telegram", .Kind = 0 }});
    try std.testing.expect(installed[3]);
}

test "install runner streams framed Shelly progress" {
    const Capture = struct {
        seen: bool = false,
        percent: u8 = 0,
        message: [64]u8 = @splat(0),
        message_len: usize = 0,

        fn update(context: *anyopaque, progress: protocol.Progress) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.seen = true;
            self.percent = progress.percent;
            self.message_len = @min(progress.text().len, self.message.len);
            @memcpy(self.message[0..self.message_len], progress.text()[0..self.message_len]);
        }
    };

    var capture: Capture = .{};
    const success = try runInstall(std.testing.allocator, &.{
        "/usr/bin/printf",
        "[JSON]eyJNZXNzYWdlIjoiSW5zdGFsbGluZyBkZW1vIiwiUGVyY2VudCI6NTV9[/JSON]",
    }, .{ .context = &capture, .function = Capture.update });
    try std.testing.expect(success);
    try std.testing.expect(capture.seen);
    try std.testing.expectEqual(@as(u8, 55), capture.percent);
    try std.testing.expectEqualStrings("Installing demo", capture.message[0..capture.message_len]);
}

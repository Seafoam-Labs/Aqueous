//! Client GPU requests derived from the renderer, not the scanout backend.
//! Environment selectors are requests; only client-side observation verifies them.
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const Pin = @This();

pub const keys = [_][:0]const u8{
    "MESA_VK_DEVICE_SELECT",     "MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE",
    "DRI_PRIME",                 "__GLX_VENDOR_LIBRARY_NAME",
    "__NV_PRIME_RENDER_OFFLOAD", "__VK_LAYER_NV_optimus",
};
pub const Identity = struct {
    node: []const u8,
    pci: []const u8,
    vendor: []const u8,
    device: []const u8,
    driver: []const u8,
};
identity: ?Identity = null,
state: enum { unavailable, unsupported, ambiguous, requested, inherited } = .unavailable,
// Null clears a managed selector; it never means preserve an inherited value.
values: [keys.len]?[:0]u8 = @splat(null),

pub fn deinit(self: *Pin, allocator: mem.Allocator) void {
    if (self.identity) |id| inline for (std.meta.fields(Identity)) |field| allocator.free(@field(id, field.name));
    for (self.values) |value| if (value) |v| allocator.free(v);
    self.* = .{};
}

extern fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern fn unsetenv([*:0]const u8) c_int;

pub fn apply(self: Pin) !void {
    if (self.state == .inherited) return;
    for (keys, self.values) |key, value| {
        const rc = if (value) |v| setenv(key, v, 1) else unsetenv(key);
        if (rc != 0) return error.SetEnvironmentFailed;
    }
}

pub fn managed(name: []const u8) bool {
    for (keys) |key| if (mem.eql(u8, name, key)) return true;
    return false;
}

fn pciValid(pci: []const u8) bool {
    if (pci.len != 12 or pci[4] != ':' or pci[7] != ':' or pci[10] != '.') return false;
    for (pci, 0..) |ch, i| {
        if (i == 4 or i == 7 or i == 10) continue;
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

/// Pure policy builder, also used by topology tests. Duplicate PCI IDs must
/// never be advertised as an exact Vulkan pin.
pub fn build(allocator: mem.Allocator, id: Identity, matches: usize, inherit: bool, offload: bool) !Pin {
    var result: Pin = .{};
    errdefer result.deinit(allocator);
    var owned: Identity = undefined;
    inline for (std.meta.fields(Identity), 0..) |field, index| {
        @field(owned, field.name) = allocator.dupe(u8, @field(id, field.name)) catch |err| {
            inline for (std.meta.fields(Identity)[0..index]) |previous| allocator.free(@field(owned, previous.name));
            return err;
        };
    }
    result.identity = owned;
    if (inherit) {
        result.state = .inherited;
        return result;
    }
    if (!pciValid(id.pci) or id.vendor.len != 4 or id.device.len != 4) {
        result.state = .unsupported;
        return result;
    }
    for (id.vendor) |ch| if (!std.ascii.isHex(ch)) return error.InvalidDeviceId;
    for (id.device) |ch| if (!std.ascii.isHex(ch)) return error.InvalidDeviceId;
    result.state = if (matches == 1) .requested else .ambiguous;
    if (matches == 1) result.values[0] = try std.fmt.allocPrintSentinel(allocator, "{s}:{s}!", .{ id.vendor, id.device }, 0);
    const nvidia = mem.eql(u8, id.driver, "nvidia") or mem.eql(u8, id.driver, "nvidia-drm");
    if (nvidia) {
        // GLX vendor selection is not proof of Wayland EGL device selection.
        result.values[3] = try allocator.dupeZ(u8, "nvidia");
        if (offload) {
            result.values[4] = try allocator.dupeZ(u8, "1");
            result.values[5] = try allocator.dupeZ(u8, "NVIDIA_only");
        }
        // NVIDIA_only selects a vendor, not a particular PCI device. The
        // Mesa selector remains necessary and actual creation must be checked.
    } else {
        var tag: [12]u8 = undefined;
        for (id.pci, 0..) |ch, i| tag[i] = if (ch == ':' or ch == '.') '_' else ch;
        result.values[2] = try std.fmt.allocPrintSentinel(allocator, "pci-{s}", .{tag}, 0);
    }
    return result;
}

fn read(path: [:0]const u8, out: []u8) ?[]const u8 {
    const rc = linux.open(path, .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, out.ptr, out.len);
    if (linux.errno(n) != .SUCCESS or n == 0 or n == out.len) return null;
    return mem.trim(u8, out[0..n], " \t\r\n");
}

fn link(path: [:0]const u8, out: []u8) ?[]const u8 {
    const n = linux.readlink(path, out.ptr, out.len);
    if (linux.errno(n) != .SUCCESS or n == out.len) return null;
    return out[0..n];
}

fn attribute(node: []const u8, name: []const u8, out: []u8) ?[]const u8 {
    var path: [512]u8 = undefined;
    const value = read(std.fmt.bufPrintZ(&path, "/sys/class/drm/{s}/device/{s}", .{ node, name }) catch return null, out) orelse return null;
    return if (mem.startsWith(u8, value, "0x")) value[2..] else value;
}

fn matchingDevices(vendor: []const u8, device: []const u8) ?usize {
    const rc = linux.open("/sys/class/drm", .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var count: usize = 0;
    var entries: [4096]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &entries, entries.len);
        if (linux.errno(n) != .SUCCESS) return null;
        if (n == 0) return count;
        var offset: usize = 0;
        while (offset < n) {
            const entry: *linux.dirent64 = @ptrCast(@alignCast(&entries[offset]));
            const name = mem.span(@as([*:0]const u8, @ptrCast(&entries[offset + @offsetOf(linux.dirent64, "name")])));
            offset += entry.reclen;
            if (!mem.startsWith(u8, name, "renderD")) continue;
            var v: [32]u8 = undefined;
            var d: [32]u8 = undefined;
            if (mem.eql(u8, vendor, attribute(name, "vendor", &v) orelse return null) and
                mem.eql(u8, device, attribute(name, "device", &d) orelse return null)) count += 1;
        }
    }
}

pub fn resolve(allocator: mem.Allocator, drm_fd: c_int, inherit: bool) Pin {
    const unavailable: Pin = .{ .state = if (inherit) .inherited else .unavailable };
    if (drm_fd < 0) return unavailable;
    var path: [512]u8 = undefined;
    var node: [256]u8 = undefined;
    const node_path = link(std.fmt.bufPrintZ(&path, "/proc/self/fd/{d}", .{drm_fd}) catch return unavailable, &node) orelse return unavailable;
    const name = std.fs.path.basename(node_path);
    var pci: [512]u8 = undefined;
    const pci_path = link(std.fmt.bufPrintZ(&path, "/sys/class/drm/{s}/device", .{name}) catch return unavailable, &pci) orelse return unavailable;
    var driver: [512]u8 = undefined;
    const driver_path = link(std.fmt.bufPrintZ(&path, "/sys/class/drm/{s}/device/driver", .{name}) catch return unavailable, &driver) orelse "";
    var vendor: [32]u8 = undefined;
    var device: [32]u8 = undefined;
    const id: Identity = .{
        .node = node_path,
        .pci = std.fs.path.basename(pci_path),
        .vendor = attribute(name, "vendor", &vendor) orelse return unavailable,
        .device = attribute(name, "device", &device) orelse return unavailable,
        .driver = std.fs.path.basename(driver_path),
    };
    var boot: [32]u8 = undefined;
    const offload = !mem.eql(u8, attribute(name, "boot_vga", &boot) orelse "", "1");
    return build(allocator, id, matchingDevices(id.vendor, id.device) orelse 0, inherit, offload) catch unavailable;
}

test "selection requests restrict unique IDs and never claim duplicate GPUs are pinned" {
    const allocator = std.testing.allocator;
    const id: Identity = .{ .node = "/dev/dri/renderD128", .pci = "0000:01:00.0", .vendor = "1002", .device = "1234", .driver = "amdgpu" };
    var unique = try build(allocator, id, 1, false, false);
    defer unique.deinit(allocator);
    try std.testing.expectEqualStrings("1002:1234!", unique.values[0].?);
    try std.testing.expectEqualStrings("pci-0000_01_00_0", unique.values[2].?);
    var duplicate = try build(allocator, id, 2, false, false);
    defer duplicate.deinit(allocator);
    try std.testing.expectEqual(.ambiguous, duplicate.state);
    try std.testing.expectEqual(null, duplicate.values[0]);
    var inherited = try build(allocator, id, 1, true, false);
    defer inherited.deinit(allocator);
    try std.testing.expectEqual(.inherited, inherited.state);
    for (inherited.values) |value| try std.testing.expectEqual(null, value);
    var nvidia_id = id;
    nvidia_id.driver = "nvidia";
    var nvidia = try build(allocator, nvidia_id, 1, false, true);
    defer nvidia.deinit(allocator);
    try std.testing.expectEqual(null, nvidia.values[2]);
    try std.testing.expectEqualStrings("nvidia", nvidia.values[3].?);
    try std.testing.expectEqualStrings("1", nvidia.values[4].?);
    var platform = id;
    platform.pci = "platform-gpu";
    var unsupported = try build(allocator, platform, 1, false, false);
    defer unsupported.deinit(allocator);
    try std.testing.expectEqual(.unsupported, unsupported.state);
}

test "NVIDIA to Mesa to unavailable clears incompatible inherited selectors" {
    const a = std.testing.allocator;
    var saved: [keys.len]?[:0]u8 = @splat(null);
    for (keys, 0..) |key, i| if (std.c.getenv(key)) |value| {
        saved[i] = try a.dupeZ(u8, mem.span(value));
    };
    defer for (keys, saved) |key, value| {
        if (value) |v| {
            _ = setenv(key, v, 1);
            a.free(v);
        } else {
            _ = unsetenv(key);
        }
    };
    for (keys) |key| try std.testing.expectEqual(@as(c_int, 0), setenv(key, "stale", 1));
    var pin = try build(a, .{ .node = "/dev/dri/renderD129", .pci = "0000:02:00.0", .vendor = "8086", .device = "1234", .driver = "i915" }, 1, false, false);
    defer pin.deinit(a);
    try pin.apply();
    try std.testing.expectEqualStrings("8086:1234!", mem.span(std.c.getenv(keys[0]).?));
    try std.testing.expectEqual(null, std.c.getenv("__NV_PRIME_RENDER_OFFLOAD"));
    try std.testing.expectEqual(null, std.c.getenv("MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE"));
    try (Pin{ .state = .inherited }).apply();
    try std.testing.expectEqualStrings("pci-0000_02_00_0", mem.span(std.c.getenv("DRI_PRIME").?));
    try (Pin{}).apply();
    for (keys) |key| try std.testing.expectEqual(null, std.c.getenv(key));
}

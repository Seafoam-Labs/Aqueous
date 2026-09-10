const std = @import("std");
const theme = @import("../../model/theme.zig");
const process = @import("process");
const a = std.heap.page_allocator;
extern fn aq_theme_watch_open() c_int;
extern fn aq_theme_watch_add(c_int, [*:0]const u8) void;
extern fn aq_theme_watch_changed(c_int) c_int;
pub const Status = enum { builtin, loading, applied, missing, invalid, font_fallback };
pub const Result = struct {
    arena: std.heap.ArenaAllocator = .init(a),
    snapshot: theme.Snapshot = .{},
    status: Status = .builtin,
    hash: u64 = 0,
    valid: bool = false,
    unchanged: bool = false,
    fonts_changed: bool = false,
    fonts: [4]?[]const u8 = @splat(null),
    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = .{};
    }
};
pub const Service = struct {
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    palettes: [2][]const u8,
    settings: [3][]const u8,
    source: theme.Source = .builtin,
    generation: u64 = 0,
    job_source: theme.Source = .builtin,
    job_generation: u64 = 0,
    job_font: theme.FontSpec = .{},
    job_hash: ?u64 = null,
    job_font_fallback: bool = false,
    last_hash: ?u64 = null,
    last_font: theme.FontSpec = .{},
    last_font_fallback: bool = false,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    next_check: i64 = 0,
    watch: c_int = -1,
    parents: [5][:0]const u8 = undefined,
    result: Result = .{},

    pub fn init(io: std.Io, env: *std.process.Environ.Map) !Service {
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const home = env.get("HOME") orelse return error.MissingHome;
        const config = env.get("XDG_CONFIG_HOME") orelse try std.fs.path.join(alloc, &.{ home, ".config" });
        const cache = env.get("XDG_CACHE_HOME") orelse try std.fs.path.join(alloc, &.{ home, ".cache" });
        const state = env.get("NOCTALIA_STATE_HOME") orelse env.get("XDG_STATE_HOME") orelse try std.fs.path.join(alloc, &.{ home, ".local/state" });
        var service: Service = .{ .io = io, .arena = arena, .palettes = .{
            try std.fs.path.join(alloc, &.{ cache, "aqueous/settings-application/themes/dms.json" }),
            try std.fs.path.join(alloc, &.{ cache, "aqueous/settings-application/themes/noctalia.json" }),
        }, .settings = .{
            try std.fs.path.join(alloc, &.{ config, "DankMaterialShell/settings.json" }),
            try alloc.dupe(u8, env.get("NOCTALIA_CONFIG") orelse try std.fs.path.join(alloc, &.{ config, "noctalia/config.toml" })),
            try std.fs.path.join(alloc, &.{ state, "noctalia/settings.toml" }),
        } };
        const paths = service.palettes ++ service.settings;
        for (paths, 0..) |path, i| service.parents[i] = try alloc.dupeZ(u8, std.fs.path.dirname(path).?);
        service.arena = arena;
        service.watch = aq_theme_watch_open();
        return service;
    }
    pub fn select(self: *Service, source: theme.Source) void {
        if (source == self.source) return;
        self.source = source;
        self.generation +%= 1;
        self.last_hash = null;
        self.last_font = .{};
        self.last_font_fallback = false;
        self.next_check = 0;
    }
    pub fn deinit(self: *Service) void {
        if (self.thread) |thread| thread.join();
        if (self.watch >= 0) _ = std.c.close(self.watch);
        self.result.deinit();
        self.arena.deinit();
    }
    pub fn poll(self: *Service) !bool {
        if (self.thread != null and self.done.load(.acquire)) {
            self.thread.?.join();
            self.thread = null;
            if (self.job_generation == self.generation) {
                // A missing export still yields usable typography, so its progress is
                // recorded as well; only an unreadable source retries on the next poll.
                if (self.result.valid or self.result.status == .missing) {
                    self.last_hash = self.result.hash;
                    self.last_font = self.result.snapshot.font;
                    self.last_font_fallback = self.result.status == .font_fallback;
                } else if (!self.result.unchanged) self.last_hash = null;
                return !self.result.unchanged;
            }
            self.result.deinit();
        }
        // Bounded polling also covers missing directories and atomic replacement.
        // No files or commands are read on the rendering thread.
        const now = std.Io.Clock.awake.now(self.io).toMilliseconds();
        if (aq_theme_watch_changed(self.watch) != 0) self.next_check = now + 200;
        if (self.thread != null or now < self.next_check) return false;
        self.next_check = now + 500;
        for (self.parents) |parent| aq_theme_watch_add(self.watch, parent);
        self.job_source = self.source;
        self.job_generation = self.generation;
        self.job_font = self.last_font;
        self.job_hash = self.last_hash;
        self.job_font_fallback = self.last_font_fallback;
        self.result.deinit();
        self.done.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
        return false;
    }
    fn read(self: *Service, alloc: std.mem.Allocator, path: []const u8, limit: usize) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, alloc, .limited(limit));
    }
    fn worker(self: *Service) void {
        defer self.done.store(true, .release);
        self.load() catch |err| {
            self.result.status = if (err == error.FileNotFound) .missing else .invalid;
        };
    }
    fn load(self: *Service) !void {
        const alloc = self.result.arena.allocator();
        const source = self.job_source;
        var settings: [3][]const u8 = .{ "", "", "" };
        var palette: ?[]const u8 = null;
        if (source != .builtin) {
            for (self.settings, 0..) |path, i| {
                if ((source == .dms) != (i == 0)) continue;
                settings[i] = self.read(alloc, path, 1024 * 1024) catch |err| if (err == error.FileNotFound) "" else return err;
            }
            palette = self.read(alloc, self.palettes[if (source == .dms) 0 else 1], 65536) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
        }
        var hash = std.hash.Wyhash.init(0);
        hash.update(@tagName(source));
        hash.update(if (palette == null) "absent" else "present");
        if (palette) |bytes| hash.update(bytes);
        for (settings) |s| {
            var len: [8]u8 = undefined;
            std.mem.writeInt(u64, &len, s.len, .little);
            hash.update(&len);
            hash.update(s);
        }
        self.result.hash = hash.final();
        if (self.job_hash == self.result.hash) {
            self.result.unchanged = true;
            return;
        }
        // Typography is read from the shell's own settings, so it stays available when
        // no palette export has been generated. Colors still require the export.
        var typography: theme.Snapshot = .{ .source = source };
        if (source == .dms) {
            typography.font.pixels = 14;
            if (settings[0].len > 0) try @import("dms.zig").typography(alloc, settings[0], &typography);
        } else if (source == .noctalia) {
            for (settings[1..]) |s| if (s.len > 0) try @import("noctalia.zig").typography(alloc, s, &typography);
        }
        var snapshot = if (palette) |bytes| try theme.decode(alloc, bytes, source) else theme.Snapshot{};
        snapshot.font = typography.font;
        snapshot.radius = typography.radius;
        self.result.snapshot = snapshot;
        self.result.fonts_changed = self.job_hash == null or !std.meta.eql(self.job_font, snapshot.font);
        self.result.status = if (!self.result.fonts_changed and self.job_font_fallback)
            .font_fallback
        else if (source == .builtin)
            .builtin
        else if (palette == null)
            .missing
        else
            .applied;
        if (self.result.fonts_changed) self.resolveFonts(alloc, &snapshot.font, palette != null and source != .builtin);
        // The built-in appearance is complete on its own; a shell appearance is not
        // until its palette export exists.
        self.result.valid = palette != null or source == .builtin;
    }
    /// Resolves the four faces from the family the shell names. A shell that names none,
    /// or one Fontconfig cannot serve, falls back to Fontconfig's default sans; Quark's
    /// embedded faces stay the last resort for a system without usable fonts.
    fn resolveFonts(self: *Service, alloc: std.mem.Allocator, spec: *const theme.FontSpec, colors: bool) void {
        if (spec.length == 0) {
            self.loadDefault(alloc, spec);
            return;
        }
        if (self.loadFonts(alloc, spec)) |exact| {
            if (!exact and colors) self.result.status = .font_fallback;
            return;
        } else |_| {}
        self.result.fonts = @splat(null);
        self.loadDefault(alloc, spec);
        if (colors) self.result.status = .font_fallback;
    }
    fn loadDefault(self: *Service, alloc: std.mem.Allocator, spec: *const theme.FontSpec) void {
        var generic: theme.FontSpec = .{ .pixels = spec.pixels, .weight = spec.weight };
        generic.setName("sans-serif") catch return;
        if (self.loadFonts(alloc, &generic)) |_| {} else |_| self.result.fonts = @splat(null);
    }
    fn loadFonts(self: *Service, alloc: std.mem.Allocator, spec: *const theme.FontSpec) !bool {
        // Fontconfig patterns escape family punctuation; no shell is involved.
        var escaped: std.Io.Writer.Allocating = .init(alloc);
        for (spec.name()) |ch| {
            if (std.mem.indexOfScalar(u8, "\\-:,=", ch) != null) try escaped.writer.writeByte('\\');
            try escaped.writer.writeByte(ch);
        }
        var exact = true;
        for (0..4) |i| {
            const weight: u16 = if (i == 1 or i == 3) @max(700, spec.weight) else spec.weight;
            const fc_weight: u16 = if (weight >= 700) 200 else if (weight >= 600) 180 else if (weight >= 500) 100 else if (weight <= 300) 50 else 80;
            const pattern = try std.fmt.allocPrint(alloc, "{s}:weight={d}:slant={d}", .{ escaped.written(), fc_weight, @as(u16, if (i >= 2) 100 else 0) });
            var response = try process.runLimited(alloc, &.{ "fc-match", "-f", "%{family}\n%{file}", pattern }, "", 700, 4096, 4096);
            defer response.deinit();
            if (response.status != 0 or response.exit_code != 0) return error.FontUnavailable;
            const newline = std.mem.indexOfScalar(u8, response.stdout(), '\n') orelse return error.FontUnavailable;
            const file = response.stdout()[newline + 1 ..];
            if (!std.fs.path.isAbsolute(file)) return error.FontUnavailable;
            if (!std.mem.eql(u8, spec.name(), "sans-serif") and !std.mem.eql(u8, spec.name(), "serif") and !std.mem.eql(u8, spec.name(), "monospace")) {
                var names = std.mem.splitScalar(u8, response.stdout()[0..newline], ',');
                while (names.next()) |name| {
                    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, name, " "), spec.name())) break;
                } else exact = false;
            }
            self.result.fonts[i] = try self.read(alloc, file, 16 * 1024 * 1024);
        }
        return exact;
    }
};

test "theme reader rejects stale sources, recovers after partial writes and owns no canonical writer" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(path);
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", path);
    try env.put("XDG_CACHE_HOME", path);
    try env.put("XDG_CONFIG_HOME", path);
    try env.put("XDG_STATE_HOME", path);
    var service = try Service.init(io, &env);
    defer service.deinit();
    const dms = try theme.encode(alloc, .dms, .dark, .{}, .{});
    defer alloc.free(dms);
    const noctalia = try theme.encode(alloc, .noctalia, .light, .{}, .{ .background = 0xffffff });
    defer alloc.free(noctalia);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(service.palettes[0]).?);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = service.palettes[0], .data = dms });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = service.palettes[1], .data = noctalia });
    service.select(.dms);
    _ = try service.poll();
    service.select(.noctalia);
    try waitResult(&service);
    try std.testing.expectEqual(theme.Source.noctalia, service.result.snapshot.source);
    try std.testing.expectEqual(@as(u32, 0xffffff), service.result.snapshot.palette.background);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = service.palettes[1], .data = "{" });
    try waitResult(&service);
    try std.testing.expect(!service.result.valid);
    try std.testing.expectEqual(Status.invalid, service.result.status);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = service.palettes[1], .data = noctalia });
    try waitResult(&service);
    try std.testing.expect(service.result.valid);
    try std.testing.expectEqual(Status.applied, service.result.status);
    // Updating an inactive source cannot change the active palette.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = service.palettes[0], .data = "broken" });
    service.job_source = .noctalia;
    service.job_hash = null;
    service.result.deinit();
    try service.load();
    try std.testing.expectEqual(theme.Source.noctalia, service.result.snapshot.source);
}
test "typography is published without an export and Fontconfig's default is not a fallback" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(path);
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", path);
    try env.put("XDG_CACHE_HOME", path);
    try env.put("XDG_CONFIG_HOME", path);
    try env.put("XDG_STATE_HOME", path);
    var service = try Service.init(io, &env);
    defer service.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    // Built-in names no family, yet the reader now runs and offers Fontconfig's default.
    try waitResult(&service);
    try std.testing.expect(service.result.valid);
    try std.testing.expectEqual(Status.builtin, service.result.status);
    try std.testing.expect(service.result.fonts_changed);
    try std.testing.expectEqual(@as(usize, 0), service.result.snapshot.font.length);

    // Shell typography is readable without a palette export; colors are not.
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(service.settings[0]).?);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = service.settings[0], .data = "{\"fontFamily\":\"Test Sans\",\"fontScale\":1.5}" });
    service.select(.dms);
    try waitResult(&service);
    try std.testing.expect(!service.result.valid);
    try std.testing.expectEqual(Status.missing, service.result.status);
    try std.testing.expect(service.result.fonts_changed);
    try std.testing.expectEqual(@as(f32, 21), service.result.snapshot.font.pixels);
    // Recorded progress keeps an unresolved family off the 500ms re-read path.
    try std.testing.expectEqual(@as(?u64, service.result.hash), service.last_hash);

    // A family Fontconfig cannot serve is reported once colors are applied; while they are
    // not, the missing export stays the actionable message.
    var absent: theme.FontSpec = .{};
    try absent.setName("Aqueous Settings Absent Family");
    for ([_]bool{ true, false }) |colors| {
        service.result.fonts = @splat(null);
        service.result.status = if (colors) .applied else .missing;
        service.resolveFonts(arena.allocator(), &absent, colors);
        try std.testing.expectEqual(if (colors) Status.font_fallback else Status.missing, service.result.status);
    }

    // Generating the export afterwards completes the appearance.
    const dms = try theme.encode(alloc, .dms, .dark, .{}, .{});
    defer alloc.free(dms);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(service.palettes[0]).?);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = service.palettes[0], .data = dms });
    try waitResult(&service);
    try std.testing.expect(service.result.valid);
    try std.testing.expectEqual(Status.applied, service.result.status);
}
fn waitResult(service: *Service) !void {
    const deadline = std.Io.Clock.awake.now(service.io).toMilliseconds() + 5000;
    while (!try service.poll()) {
        if (std.Io.Clock.awake.now(service.io).toMilliseconds() > deadline) return error.ThemeTestTimedOut;
        var delay = std.c.timespec{ .sec = 0, .nsec = 5_000_000 };
        _ = std.c.nanosleep(&delay, null);
    }
}

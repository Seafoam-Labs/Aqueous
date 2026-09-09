const std = @import("std");
test {
    _ = @import("model/rule_editor.zig");
    _ = @import("model/presentation.zig");
    _ = @import("model/search.zig");
    _ = @import("model/runtime_layout.zig");
    _ = @import("model/theme.zig");
    _ = @import("services/theme/dms.zig");
    _ = @import("services/theme/noctalia.zig");
    _ = @import("services/theme/service.zig");
    _ = @import("services/preferences.zig");
}
const model = @import("model/draft.zig");
const j = model.j;
const client = @import("process");
test "raw and typed conflicts preserve the draft" {
    var m = model.Model.init(std.testing.allocator);
    defer m.deinit();
    m.snapshot = try j.parse(m.allocator(),
        \\{"generation":"1","fields":[{"id":"input.rate","file":"input","type":"integer","min":1,"max":100,"value":25}],"raw_files":{"input":"old"}}
    );
    try m.clear();
    try m.input("input.rate", "30");
    try m.raw("input", "new");
    try std.testing.expectError(error.RawTypedConflict, m.request("/tmp/backups"));
    try std.testing.expectEqual(@as(usize, 2), m.count());
    try m.raw("input", "old");
    const request = try j.parse(m.allocator(), try m.request("/tmp/backups"));
    try std.testing.expectEqualStrings("1", j.text(request, "expected_generation"));
    try std.testing.expectEqual(@as(i64, 30), j.get(j.items(j.get(request, "changes"))[0], "value").integer);
    try std.testing.expectError(error.AboveMaximum, m.input("input.rate", "101"));
}
test "ordered rules cannot mix a move with edits" {
    var m = model.Model.init(std.testing.allocator);
    defer m.deinit();
    try m.clear();
    try m.rule(try j.parse(m.allocator(), "{\"op\":\"move\",\"id\":\"rule:0\",\"direction\":1}"));
    try std.testing.expectError(error.ApplyRuleMoveFirst, m.rule(try j.parse(m.allocator(), "{\"op\":\"update\",\"id\":\"rule:1\",\"values\":{}}")));
}

test "accepted snapshots keep rule array allocators attached to the model" {
    var m = model.Model.init(std.testing.allocator);
    defer m.deinit();
    try m.accept(
        \\{"ok":true,"protocol":1,"generation":"loaded","fields":[],"raw_files":{},"window_rules":[{"id":"rule:0","values":{"app_id":"test","blur":false}}]}
    , "none");
    try std.testing.expectEqual(m.allocator().ptr, j.get(m.draft, "window_rule_changes").array.allocator.ptr);
    try std.testing.expectEqual(m.allocator().ptr, j.get(m.snapshot, "window_rules").array.allocator.ptr);
    try m.rule(try j.parse(m.allocator(), "{\"op\":\"update\",\"id\":\"rule:0\",\"values\":{\"blur\":true,\"opacity\":0.75}}"));
    const rows = j.items(try m.rows("window_rules", "window_rule_changes"));
    try std.testing.expect(j.boolean(j.get(j.get(rows[0], "values"), "blur")));
    try std.testing.expectEqual(@as(f64, 0.75), j.number(j.get(j.get(rows[0], "values"), "opacity")));
    _ = try m.request("/tmp/backups");
}
test "transport drains stderr and stdin independently and times out" {
    var result = try client.run(std.testing.allocator, &.{ "python3", "-c", "import sys; sys.stderr.write('e'*60000); sys.stderr.flush(); print(sys.stdin.read())" }, "literal $() `command`", 3000);
    defer result.deinit();
    try std.testing.expectEqual(@as(c_int, 0), result.status);
    try std.testing.expectEqualStrings("literal $() `command`\n", result.stdout());
    var timeout = try client.run(std.testing.allocator, &.{ "python3", "-c", "import time; time.sleep(5)" }, "", 60);
    defer timeout.deinit();
    try std.testing.expectEqual(@as(c_int, 2), timeout.status);
    var missing = try client.run(std.testing.allocator, &.{"/does-not-exist-aqueous-settings"}, "", 100);
    defer missing.deinit();
    try std.testing.expectEqual(@as(c_int, 1), missing.status);
}

test {
    _ = @import("model/display_modes.zig");
}

test "failed snapshot discovery preserves loaded configuration and drafts" {
    var m = model.Model.init(std.testing.allocator);
    defer m.deinit();
    m.snapshot = try j.parse(m.allocator(), "{\"generation\":\"old\"}");
    try m.clear();
    try m.flag("sync_cursor");
    try std.testing.expectError(error.InvalidSnapshot, m.accept("{\"ok\":true,\"protocol\":1,\"generation\":\"new\",\"fields\":null,\"raw_files\":{}}", "none"));
    try std.testing.expectEqualStrings("old", j.text(m.snapshot, "generation"));
    try std.testing.expectEqual(@as(usize, 1), m.count());
}
test "new rules can be edited and removed before applying" {
    var m = model.Model.init(std.testing.allocator);
    defer m.deinit();
    try m.clear();
    try m.rule(try j.parse(m.allocator(), "{\"id\":\"new-rule:1\",\"op\":\"add\",\"values\":{\"app_id\":\"one\"}}"));
    try m.rule(try j.parse(m.allocator(), "{\"id\":\"new-rule:1\",\"op\":\"update\",\"values\":{\"title\":\"two\"}}"));
    const op = j.items(j.get(m.draft, "window_rule_changes"))[0];
    try std.testing.expectEqualStrings("add", j.text(op, "op"));
    try std.testing.expectEqualStrings("one", j.text(j.get(op, "values"), "app_id"));
    try m.rule(try j.parse(m.allocator(), "{\"id\":\"new-rule:1\",\"op\":\"delete\"}"));
    try std.testing.expectEqual(@as(usize, 0), m.count());
}
test "monitor movement retains mode scale and mirroring drafts" {
    var m = model.Model.init(std.testing.allocator);
    defer m.deinit();
    try m.clear();
    m.snapshot = try j.parse(m.allocator(), "{\"generation\":\"1\",\"fields\":[]}");
    try m.merge("monitor_changes", "live:DP-1", "mode", try j.string(m.allocator(), "1920x1080@59.94"));
    try m.merge("monitor_changes", "live:DP-1", "x", .{ .integer = -10 });
    try m.merge("monitor_changes", "live:DP-1", "scale", .{ .float = 1.5 });
    try m.merge("monitor_changes", "live:DP-1", "mirror_of", try j.string(m.allocator(), "HDMI-A-1"));
    const request = try j.parse(m.allocator(), try m.request("/tmp/backup"));
    const monitor = j.items(j.get(request, "monitor_changes"))[0];
    try std.testing.expectEqualStrings("1920x1080@59.94", j.text(monitor, "mode"));
    try std.testing.expectEqual(@as(f64, 1.5), j.number(j.get(monitor, "scale")));
    try std.testing.expectEqualStrings("HDMI-A-1", j.text(monitor, "mirror_of"));
}
test "bounded transport kills children with oversized output" {
    var result = try client.run(std.testing.allocator, &.{ "python3", "-c", "import sys; sys.stderr.write('x'*1000000)" }, "", 2000);
    defer result.deinit();
    try std.testing.expectEqual(@as(c_int, 3), result.status);
    try std.testing.expect(result.err_len <= 64 * 1024);
}
test "shortcut fields use comma separated chords and support unbinding" {
    var m = model.Model.init(std.testing.allocator);
    defer m.deinit();
    try m.clear();
    m.snapshot = try j.parse(m.allocator(), "{\"fields\":[{\"id\":\"terminal\",\"type\":\"string_list\",\"value\":[]}]}");
    try m.input("terminal", "Super+Return, Super+T");
    try std.testing.expectEqual(@as(usize, 2), j.items(m.getValue("terminal")).len);
    try m.input("terminal", "");
    try std.testing.expectEqual(@as(usize, 0), m.count());
}
test "new collection identifiers do not collide with saved data" {
    var m = model.Model.init(std.testing.allocator);
    defer m.deinit();
    try m.clear();
    m.snapshot = try j.parse(m.allocator(), "{\"snap_layouts\":[{\"id\":\"layout1\"},{\"id\":\"layout2\"}]}");
    try std.testing.expectEqualStrings("layout3", try m.unique("layout"));
}

test "disconnected draft-only monitor remains editable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const snapshot = try j.parse(a, "{\"monitors\":[],\"live_outputs\":[],\"generation\":\"base\"}");
    const edits = try j.parse(a, "{\"monitor_changes\":{\"live:TEST\":{\"id\":\"live:TEST\",\"name\":\"TEST\",\"scale\":1.5,\"x\":-100,\"mode\":\"1920x1080@59.94\"}}}");
    const merged = try @import("model/display_modes.zig").monitors(a, snapshot, edits);
    try std.testing.expectEqual(@as(usize, 1), j.items(merged).len);
    try std.testing.expectEqual(@as(f64, -100), j.number(j.get(j.items(merged)[0], "x")));
    try std.testing.expectEqualStrings("base", j.text(snapshot, "generation"));
}

test "embedded client serializes jobs and owns completed responses" {
    const BackendClient = @import("services/backend_client.zig").Client;
    var worker = BackendClient.init(std.testing.io);
    defer worker.deinit();
    try worker.startBackend("validate", "none", "invalid JSON");
    try std.testing.expectError(error.Busy, worker.startBackend("snapshot", "none", ""));
    while (!worker.poll()) {
        var delay = std.c.timespec{ .sec = 0, .nsec = 1000000 };
        _ = std.c.nanosleep(&delay, null);
    }
    var result = worker.result;
    worker.result = .{};
    defer result.deinit();
    try std.testing.expectEqual(@as(c_int, 1), result.exit_code);
    try std.testing.expect(!result.saved and !result.uncertain);
    var parsed_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parsed_arena.deinit();
    const response = try j.parse(parsed_arena.allocator(), result.stdout());
    try std.testing.expect(!j.boolean(j.get(response, "ok")));
    const retained = try parsed_arena.allocator().dupe(u8, result.stdout());
    try worker.startBackend("version", "none", "");
    while (!worker.poll()) {
        var delay = std.c.timespec{ .sec = 0, .nsec = 1000000 };
        _ = std.c.nanosleep(&delay, null);
    }
    try std.testing.expectEqualStrings(retained, result.stdout());
    try std.testing.expectEqual(@as(c_int, 0), worker.result.exit_code);
}

const std = @import("std");
const client = @import("process");
const j = @import("../model/json.zig");
pub fn detect(a: std.mem.Allocator) ![]const u8 {
    var dms = try client.run(a, &.{ "dms", "ipc", "call", "settings", "get", "fontFamily" }, "", 1000);
    defer dms.deinit();
    var noctalia = try client.run(a, &.{ "noctalia", "msg", "color-scheme-get" }, "", 1000);
    defer noctalia.deinit();
    const has_dms = dms.status == 0 and dms.exit_code == 0 and dms.stdout().len > 0;
    const has_noctalia = noctalia.status == 0 and noctalia.exit_code == 0 and noctalia.stdout().len > 0;
    return if (has_dms and !has_noctalia) "dms" else if (has_noctalia and !has_dms) "noctalia" else "none";
}
pub fn syncDms(a: std.mem.Allocator, json: []const u8) !void {
    const spec = try j.parse(a, json);
    // The optional bridge acknowledges persistence, unlike DMS settings.set.
    var result = try client.run(a, &.{ "dms", "ipc", "call", "aqueousSettingsAppearance", "apply", try j.encode(a, spec) }, "", 10000);
    defer result.deinit();
    if (result.status != 0 or result.exit_code != 0) return error.DmsAppearanceBridgeUnavailable;
    const response = try j.parse(a, std.mem.trim(u8, result.stdout(), " \r\n"));
    if (!j.boolean(j.get(response, "ok"))) return error.DmsAppearanceFailed;
    // Inspect after the shell has had time to complete its asynchronous save.
    var attempt: usize = 0;
    while (attempt < 20) : (attempt += 1) {
        var check = try client.run(a, &.{ "dms", "ipc", "call", "aqueousSettingsAppearance", "status" }, "", 1000);
        defer check.deinit();
        if (check.status != 0 or check.exit_code != 0) return error.DmsAppearanceFailed;
        const state = try j.parse(a, std.mem.trim(u8, check.stdout(), " \r\n"));
        if (j.number(j.get(state, "requestId")) != j.number(j.get(response, "requestId"))) return error.DmsSyncSuperseded;
        if (std.mem.eql(u8, j.text(state, "state"), "saved")) return;
        if (std.mem.eql(u8, j.text(state, "state"), "failed")) return error.DmsAppearanceFailed;
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = std.c.nanosleep(&ts, null);
    }
    return error.DmsSaveNotConfirmed;
}

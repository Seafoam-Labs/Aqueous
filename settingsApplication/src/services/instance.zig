const std = @import("std");
const client = @import("process");
const j = @import("../model/json.zig");
pub extern fn aq_instance_start(runtime: [*:0]const u8, display: [*:0]const u8, page: c_uint) c_int;
pub extern fn aq_instance_poll() c_int;
pub extern fn aq_instance_close() void;
pub fn activate(a: std.mem.Allocator) !void {
    var query = try client.run(a, &.{ "aqueousctl", "shell", "snapshot", "--json" }, "", 2000);
    defer query.deinit();
    if (query.status != 0 or query.exit_code != 0) return error.ActivationUnavailable;
    const snapshot = try j.parse(a, query.stdout());
    for (j.items(j.get(snapshot, "upsert"))) |window| {
        if (!std.mem.eql(u8, j.text(window, "kind"), "window") or !std.mem.eql(u8, j.text(window, "app_id"), "org.aqueous.Settings")) continue;
        var result = try client.run(a, &.{ "aqueousctl", "window", "activate", "--id", j.text(window, "id"), "--json" }, "", 2000);
        defer result.deinit();
        if (result.status != 0 or result.exit_code != 0) return error.ActivationUnavailable;
        return;
    }
    return error.WindowNotFound;
}

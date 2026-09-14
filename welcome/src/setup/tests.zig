const std = @import("std");
const u = @import("common.zig");
const shelly = @import("shelly.zig");
const config = @import("configuration.zig");
const session = @import("session.zig");
test "fragmented frames and invalid base64" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: u.Context = .{ .a = arena.allocator(), .io = std.testing.io, .executable = "/usr/bin/aqueous-welcome" };
    var frames: shelly.Frames = .{};
    defer frames.deinit(std.testing.allocator);
    const event = try ctx.value(.{ .@"$kind" = "alpm.info", .EventType = "TransactionDone" });
    const bytes = try std.fmt.allocPrint(ctx.a, "noise{s}", .{try shelly.encode(&ctx, event)});
    var count: usize = 0;
    for (bytes) |byte| {
        try frames.feed(std.testing.allocator, &.{byte});
        if (try frames.next(&ctx)) |actual| {
            try std.testing.expect(u.same(event, actual));
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try frames.feed(std.testing.allocator, "[JSON]not base64[/JSON]");
    try std.testing.expectError(error.InvalidFrame, frames.next(&ctx));
}
test "optional dependencies preserve supplied indices and provider validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: u.Context = .{ .a = arena.allocator(), .io = std.testing.io, .executable = "/usr/bin/aqueous-welcome" };
    const event = try ctx.parse("{\"$kind\":\"q.provider\",\"QuestionId\":\"67\",\"Options\":[{\"Index\":7},{\"Index\":19,\"IsInstalled\":true},{\"Index\":42,\"IsSelected\":false}]}");
    const answer = try shelly.optionalAnswer(&ctx, event);
    try std.testing.expect(u.same(u.get(answer, "SelectedIndices"), try ctx.parse("[7,42]")));
    try std.testing.expectError(error.SetupFailed, shelly.questionAnswer(&ctx, event, try ctx.parse("{\"choice\":0}")));
    const provider = try shelly.questionAnswer(&ctx, event, try ctx.parse("{\"choice\":42}"));
    try std.testing.expectEqual(@as(i64, 42), u.get(provider, "SelectedIndex").integer);
}
test "custom commands preserved and recognized legacy shortcuts routed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: u.Context = .{ .a = arena.allocator(), .io = std.testing.io, .executable = "/usr/bin/aqueous-welcome" };
    const snapshot = try ctx.parse("{\"generation\":\"g\",\"fields\":[{\"id\":\"actions.toggle_start_menu\",\"value\":\"custom\"},{\"id\":\"actions.screenshot\",\"value\":\"dms screenshot region\"}],\"custom_keybinds\":[{\"id\":\"old\",\"chord\":\"Super+S\",\"command\":\"spawn:dms screenshot region\"}]}");
    const request = try config.request(&ctx, snapshot);
    try std.testing.expectEqualStrings("actions.toggle_start_menu", request.preserved.array.items[0].string);
    try std.testing.expectEqualStrings("aqueous-shell-action screenshot", u.string(u.items(u.get(request.value, "changes"))[0], "value"));
    try std.testing.expectEqualStrings("spawn:aqueous-shell-action screenshot", u.string(u.items(u.get(request.value, "custom_keybind_changes"))[0], "command"));
}
test "selection parses comments and quoted keys but rejects duplicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: u.Context = .{ .a = arena.allocator(), .io = std.testing.io, .executable = "/usr/bin/aqueous-welcome" };
    try std.testing.expectEqualStrings("dms", try session.parseSelection(&ctx, "'version' = 1\r\n\"shell\" = 'dms' # retained\n"));
    try std.testing.expectError(error.SetupFailed, session.parseSelection(&ctx, "version=1\nshell=\"none\"\nshell=\"dms\"\n"));
}

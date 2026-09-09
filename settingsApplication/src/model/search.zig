const std = @import("std");
const j = @import("json.zig");
const presentation = @import("presentation.zig");
pub const Result = struct { id: []const u8, label: []const u8, section: []const u8, page: usize, score: u16 };
pub const pages = [_][]const u8{ "overview", "appearance", "layouts", "input", "displays", "rules", "keybinds", "advanced" };
pub const shortcuts = [_]Result{
    .{ .id = "@overview", .label = "Current workspace layout", .section = "Live workspace", .page = 0, .score = 0 },
    .{ .id = "@theme", .label = "Application theme", .section = "DMS and Noctalia colors", .page = 1, .score = 0 },
    .{ .id = "@layouts", .label = "Snap layouts and legacy zones", .section = "Snap layouts", .page = 2, .score = 0 },
    .{ .id = "@displays", .label = "Monitor arrangement and mirroring", .section = "Connected displays", .page = 4, .score = 0 },
    .{ .id = "@rules", .label = "Window rules", .section = "Matching and placement", .page = 5, .score = 0 },
    .{ .id = "@keybinds", .label = "Custom shortcuts", .section = "Keybindings", .page = 6, .score = 0 },
    .{ .id = "@advanced", .label = "Raw TOML editor", .section = "Recovery and diagnostics", .page = 7, .score = 0 },
};
fn match(text: []const u8, query: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(text, query) != null;
}
pub fn find(a: std.mem.Allocator, fields: j.Value, query: []const u8) ![]Result {
    var results: std.ArrayList(Result) = .empty;
    const q = std.mem.trim(u8, query, " \t\n");
    if (q.len == 0) return results.toOwnedSlice(a);
    for (j.items(fields)) |field| {
        const id = j.text(field, "id");
        const label = j.text(field, "label");
        const group = presentation.section(id);
        var title: []const u8 = "Other settings";
        var keywords: []const u8 = "";
        for (presentation.sections) |s| if (std.mem.eql(u8, s.id, group)) {
            title = s.title;
            keywords = s.keywords;
            break;
        };
        const page = for (pages, 0..) |name, i| {
            if (std.mem.eql(u8, name, j.text(field, "category"))) break i;
        } else continue;
        var tokens = std.mem.tokenizeAny(u8, q, " \t");
        var all = true;
        while (tokens.next()) |word| {
            if (!match(id, word) and !match(label, word) and !match(j.text(field, "description"), word) and !match(title, word) and !match(keywords, word) and !match(pages[page], word)) {
                all = false;
                break;
            }
        }
        if (!all) continue;
        const score: u16 = if (std.ascii.eqlIgnoreCase(q, id) or std.ascii.eqlIgnoreCase(q, label)) 100 else if (std.ascii.startsWithIgnoreCase(label, q)) 80 else if (match(label, q)) 60 else 20;
        try results.append(a, .{ .id = id, .label = label, .section = title, .page = page, .score = score });
    }
    for (shortcuts) |entry| if (match(entry.label, q) or match(entry.section, q)) {
        var r = entry;
        r.score = 50;
        try results.append(a, r);
    };
    std.mem.sort(Result, results.items, {}, struct {
        fn less(_: void, l: Result, r: Result) bool {
            return if (l.score != r.score) l.score > r.score else std.mem.lessThan(u8, l.id, r.id);
        }
    }.less);
    if (results.items.len > 30) results.shrinkRetainingCapacity(30);
    return results.toOwnedSlice(a);
}
test "global search finds synonyms and ranks exact fields first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = try j.parse(a, "[{\"id\":\"opacity.value\",\"label\":\"Window opacity\",\"category\":\"appearance\"},{\"id\":\"opacity.focused\",\"label\":\"Focused opacity\",\"category\":\"appearance\"}]");
    const matches = try find(a, fields, "transparency");
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("opacity.value", (try find(a, fields, "Window opacity"))[0].id);
}

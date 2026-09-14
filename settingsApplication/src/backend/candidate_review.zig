//! Conservative preparatory review. This is deliberately not candidate_impact_v1:
//! display activation and revision-bound effective resolution are not yet available.
const std = @import("std");
const config = @import("config_document.zig");
const schema = @import("schema.zig");
const Allocator = std.mem.Allocator;

pub const Report = struct {
    version: u32 = 1,
    original_generation: []const u8,
    candidate_digest: []const u8,
    changed_files: []const []const u8,
    effects: []const []const u8,
    complete: bool,
    display_revision: ?[]const u8 = null,
    protected_apply: bool = false,
    reason: ?[]const u8,

    pub fn deinit(self: Report, a: Allocator) void {
        a.free(self.candidate_digest);
        a.free(self.changed_files);
    }
};

// Length-delimit every element, including paths and unmodified canonical files.
// SHA-256 binds the complete candidate, not merely its display projection.
pub fn digest(files: *const config.ConfigFiles) [64]u8 {
    return @import("display_config").document.candidateDigest(files);
}

pub fn prepare(a: Allocator, generation: []const u8, originals: [schema.file_count][]u8, files: *const config.ConfigFiles) !Report {
    var changed: std.ArrayList([]const u8) = .empty;
    errdefer changed.deinit(a);
    var unknown = false;
    for (files.items, 0..) |file, index| {
        if (std.mem.eql(u8, originals[index], file.document.source)) continue;
        try changed.append(a, @as(schema.FileId, @enumFromInt(index)).name());
        // Only byte-identical parser input after removal of comments/line padding
        // is proven harmless. Any unproven semantics remain gated.
        if (!try triviaOnly(a, originals[index], file.document.source)) unknown = true;
    }
    return .{
        .original_generation = generation,
        .candidate_digest = try a.dupe(u8, &digest(files)),
        .changed_files = try changed.toOwnedSlice(a),
        .effects = if (unknown) &.{"unknown"} else &.{"none"},
        .complete = !unknown,
        .reason = if (unknown) "effective_candidate_classification_unavailable" else null,
    };
}

// Match the existing parsers' quote-aware inline comment semantics. Reject
// multiline strings and malformed quotes rather than misreading their contents.
fn signature(a: Allocator, source: []const u8) !?[]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        var quote: u8 = 0;
        var escaped = false;
        var end = line.len;
        for (line, 0..) |ch, i| {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (quote == '"' and ch == '\\') {
                escaped = true;
            } else if (quote != 0) {
                if (ch == quote) quote = 0;
            } else if (ch == '#') {
                end = i;
                break;
            } else if (ch == '"' or ch == '\'') {
                if (i + 2 < line.len and line[i + 1] == ch and line[i + 2] == ch) {
                    result.deinit(a);
                    return null;
                }
                quote = ch;
            }
        }
        if (quote != 0 or escaped) {
            result.deinit(a);
            return null;
        }
        const cleaned = std.mem.trim(u8, line[0..end], " \t\r");
        if (cleaned.len == 0) continue;
        try result.appendSlice(a, cleaned);
        try result.append(a, '\n');
    }
    return try result.toOwnedSlice(a);
}

pub fn triviaOnly(a: Allocator, before: []const u8, after: []const u8) !bool {
    const left = try signature(a, before) orelse return false;
    defer a.free(left);
    const right = try signature(a, after) orelse return false;
    defer a.free(right);
    return std.mem.eql(u8, left, right);
}

test "comments are harmless but strings, false/reset, unknown keys and multiline fail closed" {
    const a = std.testing.allocator;
    try std.testing.expect(try triviaOnly(a, "[[output]]\nname = \"DP-1\"\nhdr = false\n", "# hdr = true\n [[output]] # ignored\nname = \"DP-1\"\n hdr = false # yes\n"));
    try std.testing.expect(!try triviaOnly(a, "hdr = false", "hdr = true"));
    try std.testing.expect(!try triviaOnly(a, "mirror_of = \"DP-1\"", "mirror_of = \"\""));
    try std.testing.expect(!try triviaOnly(a, "future = 1", "future = 2"));
    try std.testing.expect(!try triviaOnly(a, "value = \"# before\"", "value = \"# after\""));
    try std.testing.expect(!try triviaOnly(a, "value = \"\"\"\n[[output]]\n\"\"\"", "value = \"\"\"\n[[output]] # changed\n\"\"\""));
}

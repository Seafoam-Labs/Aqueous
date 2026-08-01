const std = @import("std");

pub const Frame = struct {
    pub const prefix = "[JSON]";
    pub const suffix = "[/JSON]";

    payload: []const u8,
    consumed: usize,

    pub fn next(buffer: []const u8) ?Frame {
        const prefix_start = std.mem.indexOf(u8, buffer, prefix) orelse return null;
        const payload_start = prefix_start + prefix.len;
        const suffix_start = std.mem.indexOfPos(u8, buffer, payload_start, suffix) orelse return null;
        return .{
            .payload = buffer[payload_start..suffix_start],
            .consumed = suffix_start + suffix.len,
        };
    }

    pub fn decode(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
        const decoder = std.base64.standard.Decoder;
        const size = try decoder.calcSizeForSlice(payload);
        const result = try allocator.alloc(u8, size);
        errdefer allocator.free(result);
        try decoder.decode(result, payload);
        return result;
    }
};

pub const Progress = struct {
    message: [192]u8 = @splat(0),
    message_len: usize = 0,
    percent: u8 = 0,

    pub fn text(self: *const Progress) []const u8 {
        return self.message[0..self.message_len];
    }
};

const Envelope = struct {
    @"$kind": []const u8 = "",
    Message: []const u8 = "",
    ErrorMessage: []const u8 = "",
    PackageName: []const u8 = "",
    Status: ?[]const u8 = null,
    Stage: ?[]const u8 = null,
    ProgressType: []const u8 = "",
    Percent: i64 = 0,
    Percentage: i64 = 0,
};

pub fn progressFromJson(allocator: std.mem.Allocator, json: []const u8) !Progress {
    const parsed = try std.json.parseFromSlice(Envelope, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const value = parsed.value;
    const message = if (value.ErrorMessage.len != 0)
        value.ErrorMessage
    else if (value.Message.len != 0)
        value.Message
    else if (value.Status) |status|
        status
    else if (value.Stage) |stage|
        stage
    else if (value.PackageName.len != 0)
        value.PackageName
    else if (value.ProgressType.len != 0)
        value.ProgressType
    else
        "Working…";

    const raw_percent = if (value.Percentage != 0) value.Percentage else value.Percent;
    var result: Progress = .{ .percent = @intCast(std.math.clamp(raw_percent, 0, 100)) };
    result.message_len = @min(message.len, result.message.len);
    @memcpy(result.message[0..result.message_len], message[0..result.message_len]);
    return result;
}

test "frame decoder handles partial and complete frames" {
    try std.testing.expect(Frame.next("[JSON]abc") == null);
    const frame = Frame.next("noise[JSON]aGVsbG8=[/JSON]tail").?;
    const decoded = try Frame.decode(std.testing.allocator, frame.payload);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("hello", decoded);
    try std.testing.expectEqual(@as(usize, 26), frame.consumed);
}

test "progress decoder accepts Shelly progress envelopes" {
    const progress = try progressFromJson(
        std.testing.allocator,
        "{\"$kind\":\"AlpmProgress\",\"PackageName\":\"firefox\",\"Percent\":42}",
    );
    try std.testing.expectEqualStrings("firefox", progress.text());
    try std.testing.expectEqual(@as(u8, 42), progress.percent);
}

// SPDX-License-Identifier: GPL-3.0-only
const Audio = @This();
const std = @import("std");
const bell = @import("system_bell.zig");
extern fn aqueous_bell_spawn(path: [*:0]const u8, volume: [*:0]const u8) c_int;
extern fn aqueous_bell_poll(pid: c_int) c_int;
extern fn aqueous_bell_signal(pid: c_int, force: c_int) void;
extern fn aqueous_bell_finish(pid: c_int) void;

pid: ?c_int = null,
deadline: u64 = 0,
cancelled: bool = false,
last_warning: ?u64 = null,

pub fn play(audio: *Audio, config: *const bell.Config, now: u64) void {
    if (audio.pid != null or !config.sound()) return;
    var volume: [32]u8 = undefined;
    const value = std.fmt.bufPrintZ(&volume, "{d:.4}", .{config.volume}) catch return;
    const pid = aqueous_bell_spawn(config.path().ptr, value.ptr);
    if (pid < 0) {
        audio.warn(now);
        return;
    }
    audio.pid = pid;
    audio.deadline = now + bell.playback_ms;
    audio.cancelled = false;
}

pub fn poll(audio: *Audio, now: u64) void {
    const pid = audio.pid orelse return;
    const result = aqueous_bell_poll(pid);
    if (result != 0) {
        if (result < 0 and !audio.cancelled) audio.warn(now);
        audio.pid = null;
        return;
    }
    if (now >= audio.deadline) {
        if (audio.cancelled) {
            aqueous_bell_signal(pid, 1);
        } else audio.cancel(now);
    }
}

pub fn cancel(audio: *Audio, now: u64) void {
    if (audio.pid) |pid| {
        if (audio.cancelled) return;
        aqueous_bell_signal(pid, 0);
        audio.cancelled = true;
        audio.deadline = now + bell.kill_grace_ms;
    }
}

pub fn deinit(audio: *Audio) void {
    if (audio.pid) |pid| aqueous_bell_finish(pid);
    audio.pid = null;
}

fn warn(audio: *Audio, now: u64) void {
    if (audio.last_warning) |last| if (now -| last < 10_000) return;
    audio.last_warning = now;
    std.log.warn("bell sound failed; check sound_file, pw-play and the PipeWire session", .{});
}

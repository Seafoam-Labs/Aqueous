// SPDX-License-Identifier: GPL-3.0-only
//! Only category presence enters this state machine. No input values/history.
const std = @import("std");
pub const Category = enum(u32) { keyboard = 1, mouse = 2 };
pub const interval_ms = 100;
pub const ack_timeout_ms = 1000;
pub const State = struct {
    generation: u64 = 1,
    sequence: u32 = 0,
    ready: bool = false,
    gate: bool = false,
    pending: u32 = 0,
    pending_at: i64 = 0,
    next_emit: i64 = 0,
    inflight: bool = false,
    sent_at: i64 = 0,
    exhausted: bool = false,

    pub fn invalidate(self: *State) void {
        self.ready = false;
        self.pending = 0;
        self.inflight = false;
        self.sequence = 0;
        if (self.generation == std.math.maxInt(u64)) self.exhausted = true else self.generation += 1;
    }
    pub fn setGate(self: *State, gate: bool) bool {
        if (self.gate == gate) return false;
        self.gate = gate;
        self.invalidate();
        return true;
    }
    pub fn setReady(self: *State, generation: u64, ready: bool, now: i64) bool {
        if (generation != self.generation or self.exhausted) return false;
        if (!ready) {
            self.invalidate();
            return true;
        }
        if (!self.gate) return false;
        if (!self.ready) self.next_emit = @max(self.next_emit, now + interval_ms);
        self.ready = true;
        return true;
    }
    pub fn available(self: State) bool {
        return self.ready and self.gate and !self.exhausted;
    }
    pub fn note(self: *State, category: Category, now: i64) void {
        if (!self.available()) return;
        if (self.pending != 0 and now - self.pending_at > interval_ms) self.pending = 0;
        if (self.pending == 0) self.pending_at = now;
        self.pending |= @intFromEnum(category);
    }
    pub fn tick(self: *State, now: i64) ?u32 {
        if (!self.available()) return null;
        if (self.inflight and now - self.sent_at >= ack_timeout_ms) {
            self.invalidate();
            return null;
        }
        if (now < self.next_emit) return null;
        self.next_emit = now + interval_ms;
        const categories = self.pending;
        self.pending = 0;
        if (self.inflight or categories == 0 or now - self.pending_at > interval_ms) return null;
        if (self.sequence == std.math.maxInt(u32)) {
            self.invalidate();
            return null;
        }
        self.sequence += 1;
        self.inflight = true;
        self.sent_at = now;
        return categories;
    }
    pub fn ack(self: *State, generation: u64, sequence: u32) bool {
        if (!self.inflight or self.generation != generation or self.sequence != sequence) return false;
        self.inflight = false;
        return true;
    }
};

/// Per-device ingress state; never crosses the compositor boundary. Tracking
/// all Linux key/button codes avoids losing held-key state on bounded overflow.
pub const Presses = struct {
    down: std.StaticBitSet(768) = .initEmpty(),
    pub fn update(self: *Presses, value: u32, pressed: bool) bool {
        if (value >= 768) return false;
        const was_down = self.down.isSet(value);
        self.down.setValue(value, pressed);
        return pressed and !was_down;
    }
};

fn enabled() State {
    var state: State = .{};
    _ = state.setGate(true);
    _ = state.setReady(state.generation, true, 0);
    return state;
}
test "presence: one and many presses are indistinguishable; mixed categories coalesce" {
    var one = enabled();
    var many = enabled();
    one.note(.keyboard, 10);
    for (0..2000) |_| many.note(.keyboard, 10);
    try std.testing.expectEqual(one.tick(100), many.tick(100));
    try std.testing.expectEqual(@as(u32, 1), one.sequence);
    try std.testing.expect(one.ack(one.generation, 1));
    one.note(.keyboard, 101);
    one.note(.mouse, 102);
    try std.testing.expectEqual(@as(?u32, 3), one.tick(200));
}
test "suspension invalidates pending/inflight activity and requires fresh readiness" {
    var s = enabled();
    const old = s.generation;
    s.note(.mouse, 20);
    _ = s.setGate(false);
    _ = s.setGate(true);
    try std.testing.expect(!s.setReady(old, true, 90));
    try std.testing.expectEqual(@as(?u32, null), s.tick(100));
    try std.testing.expect(s.setReady(s.generation, true, 100));
    try std.testing.expectEqual(@as(?u32, null), s.tick(200));
    s.note(.keyboard, 210);
    try std.testing.expectEqual(@as(?u32, 1), s.tick(300));
    _ = s.setReady(s.generation, false, 301);
    try std.testing.expect(!s.ack(old, 1));
}
test "bounded backpressure drops old buckets and times out without replay" {
    var s = enabled();
    s.note(.keyboard, 1);
    _ = s.tick(100);
    s.note(.mouse, 150);
    try std.testing.expectEqual(@as(?u32, null), s.tick(200));
    try std.testing.expect(s.ack(s.generation, 1));
    try std.testing.expectEqual(@as(?u32, null), s.tick(300));
    s.note(.mouse, 310);
    _ = s.tick(400);
    const generation = s.generation;
    _ = s.tick(1400);
    try std.testing.expect(!s.ready and s.generation != generation);
}
test "stalls and subscription churn cannot replay or bypass minimum spacing" {
    var s = enabled();
    s.note(.keyboard, 1);
    try std.testing.expectEqual(@as(?u32, null), s.tick(500));
    s.note(.mouse, 501);
    try std.testing.expectEqual(@as(?u32, null), s.tick(502));
    _ = s.setReady(s.generation, false, 503);
    _ = s.setReady(s.generation, true, 504);
    s.note(.keyboard, 505);
    try std.testing.expectEqual(@as(?u32, null), s.tick(599));
    try std.testing.expectEqual(@as(?u32, 1), s.tick(604));
}
test "held values repeat locally without additional activity, including while suspended" {
    var keys: Presses = .{};
    try std.testing.expect(keys.update(30, true));
    try std.testing.expect(!keys.update(30, true));
    try std.testing.expect(!keys.update(30, false));
    try std.testing.expect(keys.update(30, true));
    try std.testing.expect(!keys.update(768, true));
    try std.testing.expect(keys.update(767, true));
    try std.testing.expect(!keys.update(767, true));
}
test "generation and sequence exhaustion never wrap" {
    var s = enabled();
    s.sequence = std.math.maxInt(u32);
    s.note(.keyboard, 10);
    try std.testing.expectEqual(@as(?u32, null), s.tick(100));
    try std.testing.expect(!s.ready);
    s.generation = std.math.maxInt(u64);
    s.invalidate();
    try std.testing.expect(s.exhausted);
    try std.testing.expect(!s.setReady(s.generation, true, 200));
}

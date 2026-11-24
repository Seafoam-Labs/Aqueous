// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! X11 server-side decoration negotiation through `_MOTIF_WM_HINTS`.
//!
//! X11 clients have no xdg-decoration protocol; their MOTIF hints are the only
//! decoration signal. When policy configures SSD for an X11 window the
//! compositor writes hints which strip the client's own border/title, and
//! restores the client's original hints when SSD is turned off. A client which
//! insists on its own decorations (writes non-zero hints while suppressed) is
//! honored: policy sees `prefers_csd` and never forces X11 SSD, so there is no
//! hint fight. Our own writes are recognized and ignored by the hint listener.

const std = @import("std");
const build_options = @import("build_options");
const c = @import("xwayland_c");
const server = &@import("main.zig").server;
const log = std.log.scoped(.xwayland);

const hints_len = 5;
const flags_decorations: u32 = 1 << 1;

const Entry = struct {
    original: ?[hints_len]u32 = null,
    suppressed: bool = false,
};

var connection: ?*c.xcb_connection_t = null;
var motif_atom: c.xcb_atom_t = 0;
var entries: std.AutoHashMapUnmanaged(c.xcb_window_t, Entry) = .empty;
var broken: bool = false;

fn ensure() bool {
    if (!build_options.xwayland or broken) return false;
    if (connection != null) return true;
    const xwayland = server.xwayland orelse return false;
    const conn = c.xcb_connect(xwayland.display_name, null) orelse {
        broken = true;
        return false;
    };
    if (c.xcb_connection_has_error(conn) != 0) {
        c.xcb_disconnect(conn);
        broken = true;
        return false;
    }
    const name = "_MOTIF_WM_HINTS";
    const reply = c.xcb_intern_atom_reply(conn, c.xcb_intern_atom(conn, 0, @intCast(name.len), name.ptr), null);
    if (reply == null) {
        c.xcb_disconnect(conn);
        broken = true;
        return false;
    }
    defer c.free(reply);
    if (reply.*.atom == c.XCB_ATOM_NONE) {
        c.xcb_disconnect(conn);
        broken = true;
        return false;
    }
    motif_atom = reply.*.atom;
    connection = conn;
    return true;
}

fn readOriginal(conn: *c.xcb_connection_t, window: c.xcb_window_t) ?[hints_len]u32 {
    const reply = c.xcb_get_property_reply(conn, c.xcb_get_property(conn, 0, window, motif_atom, c.XCB_GET_PROPERTY_TYPE_ANY, 0, hints_len), null);
    if (reply == null) return null;
    defer c.free(reply);
    if (reply.*.type == c.XCB_ATOM_NONE or reply.*.format != 32) return null;
    const len: usize = @intCast(c.xcb_get_property_value_length(reply));
    if (len < hints_len * 4) return null;
    const values: [*]const u32 = @ptrCast(@alignCast(c.xcb_get_property_value(reply)));
    var original: [hints_len]u32 = undefined;
    @memcpy(&original, values[0..hints_len]);
    return original;
}

fn writeHints(conn: *c.xcb_connection_t, window: c.xcb_window_t, values: [hints_len]u32) bool {
    const cookie = c.xcb_change_property_checked(conn, c.XCB_PROP_MODE_REPLACE, window, motif_atom, motif_atom, 32, hints_len, &values);
    const err = c.xcb_request_check(conn, cookie);
    if (err != null) {
        c.free(err);
        return false;
    }
    return c.xcb_connection_has_error(conn) == 0;
}

/// Idempotently strip (suppress) or restore (unsuppress) the client's own X11
/// decorations. Called from the policy visual pass on every manage cycle.
pub fn setSuppressed(window: c.xcb_window_t, suppress: bool) void {
    if (!ensure()) return;
    const conn = connection.?;
    const entry = entries.getOrPut(std.heap.c_allocator, window) catch return;
    if (entry.found_existing and entry.value_ptr.suppressed == suppress) return;
    if (!suppress and !entry.found_existing) {
        // Never suppressed: leave the client's own hints untouched.
        _ = entries.remove(window);
        return;
    }
    if (suppress) {
        if (!entry.found_existing) entry.value_ptr.* = .{};
        if (entry.value_ptr.original == null) entry.value_ptr.original = readOriginal(conn, window);
        const stripped = [hints_len]u32{ flags_decorations, 0, 0, 0, 0 };
        if (!writeHints(conn, window, stripped)) {
            broken = true;
            return;
        }
        entry.value_ptr.suppressed = true;
    } else {
        if (entry.value_ptr.original) |original| {
            if (!writeHints(conn, window, original)) {
                broken = true;
                return;
            }
        } else {
            _ = c.xcb_delete_property(conn, window, motif_atom);
        }
        entry.value_ptr.suppressed = false;
    }
    _ = c.xcb_flush(conn);
}

/// True when the hint event matches our own suppression write, so the hint
/// listener must not flip the window back to `prefers_csd`.
pub fn matchesSuppression(window: c.xcb_window_t, no_border: bool, no_title: bool) bool {
    const entry = entries.get(window) orelse return false;
    return entry.suppressed and no_border and no_title;
}

/// Drop tracking for a window which is going away (no restore: the X11 window
/// is destroyed or will be re-negotiated on remap).
pub fn forget(window: c.xcb_window_t) void {
    _ = entries.remove(window);
}

/// Restore every suppressed window and close the connection (server teardown).
pub fn deinit() void {
    if (connection) |conn| {
        var it = entries.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.suppressed) continue;
            if (entry.value_ptr.original) |original| {
                _ = writeHints(conn, entry.key_ptr.*, original);
            } else {
                _ = c.xcb_delete_property(conn, entry.key_ptr.*, motif_atom);
            }
        }
        _ = c.xcb_flush(conn);
        c.xcb_disconnect(conn);
        connection = null;
    }
    entries.deinit(std.heap.c_allocator);
    entries = .empty;
    broken = false;
}
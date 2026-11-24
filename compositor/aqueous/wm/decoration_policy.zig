// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Pure server-side decoration policy for the integrated window manager.
//! Kept free of compositor imports so the decision matrix is unit-testable.

const std = @import("std");

/// Mirrors aqueous_window_v1.decoration_hint.
pub const Hint = enum { only_supports_csd, prefers_csd, prefers_ssd, no_preference };

/// Decide whether a window is configured for server-side decorations.
///
/// `force_ssd` is the user's `[layout] force_ssd` preference. `shell_ssd` is
/// true when configuration selects the shell renderer and a capable shell
/// client (Pearl) is connected; the shell then draws the decorations instead
/// of the compositor's borders. Clients without an xdg-decoration object and
/// CSD-only clients always keep client-side decorations.
pub fn ssdMode(force_ssd: bool, has_xdg_decoration: bool, shell_ssd: bool, hint: Hint) bool {
    if (!has_xdg_decoration) return false;
    if (shell_ssd) {
        if (hint == .only_supports_csd) return false;
        return force_ssd or hint == .prefers_ssd;
    }
    return force_ssd;
}

/// X11 entry point. X11 clients have no negotiation protocol; their MOTIF
/// hints are the only signal, so a client which asks for its own decorations
/// (`prefers_csd`) is honored even under force_ssd — fighting the hints would
/// loop. Windows without a decoration preference follow the renderer/force
/// settings like xdg clients.
pub fn x11SsdMode(force_ssd: bool, shell_ssd: bool, hint: Hint) bool {
    if (hint == .prefers_csd or hint == .only_supports_csd) return false;
    return shell_ssd or force_ssd;
}

pub const Override = enum { csd, ssd };

/// Apply a per-window rule override to the policy decision. `capable` means
/// the client can actually run without its own decorations (xdg-decoration
/// object present, or an X11 window which does not insist on CSD). CSD-only
/// clients are never forced, even by an `ssd` rule.
pub fn withOverride(base: bool, override: ?Override, capable: bool) bool {
    const value = override orelse return base;
    return switch (value) {
        .csd => false,
        .ssd => capable,
    };
}

test "integrated SSD policy follows force setting and protocol capability" {
    try std.testing.expect(!ssdMode(false, false, false, .no_preference));
    try std.testing.expect(!ssdMode(false, true, false, .no_preference));
    try std.testing.expect(!ssdMode(true, false, false, .no_preference));
    try std.testing.expect(ssdMode(true, true, false, .no_preference));
}

test "shell SSD renderer decorates preferring and forced clients only" {
    // No xdg-decoration object: always CSD regardless of renderer.
    try std.testing.expect(!ssdMode(true, false, true, .prefers_ssd));
    // CSD-only clients keep their own decorations.
    try std.testing.expect(!ssdMode(true, true, true, .only_supports_csd));
    // Shell renderer honors explicit SSD preference without force_ssd.
    try std.testing.expect(ssdMode(false, true, true, .prefers_ssd));
    try std.testing.expect(!ssdMode(false, true, true, .prefers_csd));
    try std.testing.expect(!ssdMode(false, true, true, .no_preference));
    // force_ssd keeps its compositor-path meaning under the shell renderer.
    try std.testing.expect(ssdMode(true, true, true, .prefers_csd));
    try std.testing.expect(ssdMode(true, true, true, .no_preference));
}

test "X11 SSD honors client decoration hints even under force_ssd" {
    // A client asking for its own decorations is never forced (no hint fight).
    try std.testing.expect(!x11SsdMode(true, true, .prefers_csd));
    try std.testing.expect(!x11SsdMode(true, false, .prefers_csd));
    try std.testing.expect(!x11SsdMode(true, true, .only_supports_csd));
    // Default X11 windows follow the renderer and force settings.
    try std.testing.expect(x11SsdMode(false, true, .prefers_ssd));
    try std.testing.expect(x11SsdMode(true, false, .prefers_ssd));
    try std.testing.expect(!x11SsdMode(false, false, .prefers_ssd));
    try std.testing.expect(x11SsdMode(false, true, .no_preference));
}

test "decoration rule overrides force sides without forcing CSD-only clients" {
    // No override preserves the policy decision.
    try std.testing.expect(withOverride(true, null, true));
    try std.testing.expect(!withOverride(false, null, false));
    // csd always keeps client decorations.
    try std.testing.expect(!withOverride(true, .csd, true));
    // ssd forces server-side only for capable clients.
    try std.testing.expect(withOverride(false, .ssd, true));
    try std.testing.expect(!withOverride(false, .ssd, false));
    try std.testing.expect(!withOverride(true, .ssd, false));
}
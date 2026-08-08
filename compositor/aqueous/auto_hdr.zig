// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

//! Reference implementation of the Auto HDR highlight expansion applied to
//! SDR content on HDR outputs (see docs/auto-hdr-implementation-plan.md).
//!
//! The GPU shader in render/shaders/rounded_texture.frag mirrors these
//! formulas; unit tests here pin the curve down so shader changes remain
//! verifiable.
//!
//! Coordinate system: the linear working space of the scene, where the
//! patch-0004 luminance multiplier has already placed SDR diffuse white.
//! `white` is that multiplier (working units, 1.0 = 203 cd/m²) and `peak`
//! is the output's HDR level in the same units.

const std = @import("std");

/// Uniform parameters for one expanded texture draw.
pub const ItmParams = struct {
    /// HDR peak in working units (level_nits / 203).
    peak: f32,
    /// Expansion strength, 0..1.
    boost: f32,
};

/// Expansion strength used when a config omits `auto_hdr_boost`.
pub const default_boost: f64 = 0.5;

/// White-relative luminance where highlight expansion starts ramping in.
pub const knee: f64 = 0.8;

fn smoothstep(edge0: f64, edge1: f64, x: f64) f64 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0, 1);
    return t * t * (3.0 - 2.0 * t);
}

/// Multiplicative gain applied to a pixel of luminance `luma`.
///
/// Returns 1.0 (identity) when expansion is disabled, at or below the knee,
/// or for zero boost. The gain rises smoothly toward `1 + boost * (peak /
/// white - 1)` at SDR white and above, so only highlight regions lift while
/// midtones and shadows stay anchored.
pub fn expansionGain(luma: f64, white: f64, peak: f64, boost: f64) f64 {
    if (peak <= 0 or boost <= 0) return 1.0;
    const safe_white = @max(white, 1.0e-4);
    const x = luma / safe_white;
    const mask = smoothstep(knee, 1.0, x);
    const peak_rel = @max(peak / safe_white, 1.0);
    return 1.0 + boost * (peak_rel - 1.0) * mask;
}

/// Expanded luminance for a pixel, clamped at the HDR peak.
///
/// The clamp applies even at zero boost so extended-range inputs can never
/// exceed the level the InfoFrame advertises.
pub fn expandLuminance(luma: f64, white: f64, peak: f64, boost: f64) f64 {
    if (peak <= 0) return luma;
    const gained = luma * expansionGain(luma, white, peak, boost);
    return @min(gained, peak);
}

/// Validate an `auto_hdr_boost` configuration value.
pub fn validateBoost(value: f64) ?f64 {
    if (!std.math.isFinite(value) or value < 0.0 or value > 1.0) return null;
    return value;
}

test "zero boost leaves content unchanged below the peak" {
    for ([_]f64{ 0.0, 0.2, 0.5, 0.79, 0.9, 1.0 }) |luma| {
        try std.testing.expectEqual(luma, expandLuminance(luma, 1.0, 4.926, 0.0));
    }
}

test "zero boost still clamps extended-range inputs at the peak" {
    const peak: f64 = 1000.0 / 203.0;
    try std.testing.expectEqual(peak, expandLuminance(8.0, 1.0, peak, 0.0));
}

test "expansion is identity at and below the knee" {
    const white: f64 = 200.0 / 203.0;
    const peak: f64 = 1000.0 / 203.0;
    for ([_]f64{ 0.0, 0.3 * white, knee * white }) |luma| {
        try std.testing.expectEqual(1.0, expansionGain(luma, white, peak, 1.0));
        try std.testing.expectEqual(luma, expandLuminance(luma, white, peak, 1.0));
    }
}

test "expansion reaches the boosted peak at SDR white" {
    const white: f64 = 200.0 / 203.0;
    const peak: f64 = 1000.0 / 203.0;
    const boost: f64 = 0.5;
    const gain = expansionGain(white, white, peak, boost);
    try std.testing.expectApproxEqAbs(1.0 + boost * (peak / white - 1.0), gain, 1e-9);
    // SDR white itself lifts; the display tone maps it back toward the
    // configured SDR white level only for non-expanded content.
    try std.testing.expect(expandLuminance(white, white, peak, boost) > white);
}

test "expansion is monotonic and bounded by the peak" {
    const white: f64 = 200.0 / 203.0;
    const peak: f64 = 400.0 / 203.0;
    var previous: f64 = -1.0;
    var i: usize = 0;
    while (i <= 400) : (i += 1) {
        const luma: f64 = @as(f64, @floatFromInt(i)) / 100.0; // 0..4 in white units
        const expanded = expandLuminance(luma * white, white, peak, 0.7);
        try std.testing.expect(expanded >= previous);
        try std.testing.expect(expanded <= peak + 1e-9);
        previous = expanded;
    }
}

test "expansion gain never compresses content" {
    const white: f64 = 200.0 / 203.0;
    const peak: f64 = 1000.0 / 203.0;
    var i: usize = 0;
    while (i <= 200) : (i += 1) {
        const luma: f64 = @as(f64, @floatFromInt(i)) / 200.0 * white;
        try std.testing.expect(expansionGain(luma, white, peak, 1.0) >= 1.0);
    }
}

test "disabled expansion returns identity gain" {
    try std.testing.expectEqual(1.0, expansionGain(1.0, 1.0, 0.0, 1.0));
    try std.testing.expectEqual(1.0, expansionGain(1.0, 1.0, 4.0, 0.0));
    try std.testing.expectEqual(1.0, expansionGain(1.0, 1.0, -1.0, 1.0));
}

test "boost validation matches the documented range" {
    try std.testing.expectEqual(@as(f64, 0.0), validateBoost(0.0).?);
    try std.testing.expectEqual(@as(f64, 0.5), validateBoost(0.5).?);
    try std.testing.expectEqual(@as(f64, 1.0), validateBoost(1.0).?);
    try std.testing.expect(validateBoost(-0.1) == null);
    try std.testing.expect(validateBoost(1.5) == null);
    try std.testing.expect(validateBoost(std.math.inf(f64)) == null);
    try std.testing.expect(validateBoost(std.math.nan(f64)) == null);
}

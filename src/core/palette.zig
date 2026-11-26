//! Colours as 0xRRGGBBAA, from the tech-trio.svg palette, so modules that
//! never import raylib can still name them. web/shell.html repeats the first three.
const std = @import("std");

pub const background: u32 = 0x0E1414FF; // near-black teal
pub const teal: u32 = 0x2E7E7EFF;
pub const sand: u32 = 0xC8A878FF;

/// Partition lines between hexes; darker than the lowest, shaded ground
/// (`ground_stops[0]`), so lines show in the hollows too.
pub const line: u32 = 0x071816FF; // near-black teal
/// Partition lines on the ridges; the terrain shader blends from `line` by height.
pub const line_high: u32 = 0x7A3A1EFF; // deep copper

/// Sky straight up: deep dusk teal.
pub const sky_zenith: u32 = 0x173A48FF;
/// Sky halfway up the gradient: dusty mauve, so the haze doesn't turn grey
/// on its way to teal (the two are near complements).
pub const sky_mid: u32 = 0x8C7480FF;
/// Sky at the horizon: dusty peach haze. Distant terrain fades into it
/// (`sky.fog`), so it is also the fog colour.
pub const sky_horizon: u32 = 0xD9AB80FF;
/// The sun's disc and glow.
pub const sun: u32 = 0xFFF0D2FF; // warm white
/// The moon's crescent: decoration, it lights nothing.
pub const moon: u32 = 0xA8D8CEFF; // pale teal

/// Ground colour by height, low to high: teal hollows, sand slopes, pale crests.
pub const ground_stops = [_]u32{ 0x1E4A48FF, teal, sand, 0xE8DCB8FF };

/// Ground colour at `t` = height / max height (clamped to 0..1).
pub fn ground(t: f32) u32 {
    const last: f32 = @floatFromInt(ground_stops.len - 1);
    const x = std.math.clamp(t, 0, 1) * last;
    const i: usize = @intFromFloat(@min(@floor(x), last - 1));
    return lerp(ground_stops[i], ground_stops[i + 1], x - @as(f32, @floatFromInt(i)));
}

/// Per-channel blend: `a` at 0, `b` at 1.
pub fn lerp(a: u32, b: u32, t: f32) u32 {
    var out: u32 = 0;
    inline for (.{ 24, 16, 8, 0 }) |shift| {
        const ca: f32 = @floatFromInt((a >> shift) & 0xFF);
        const cb: f32 = @floatFromInt((b >> shift) & 0xFF);
        const c: u32 = @intFromFloat(@round(std.math.lerp(ca, cb, t)));
        out |= c << shift;
    }
    return out;
}

/// Relative luminance of `c`'s RGB (Rec. 709 weights, no gamma), 0..255.
pub fn luma(c: u32) f32 {
    const r: f32 = @floatFromInt((c >> 24) & 0xFF);
    const g: f32 = @floatFromInt((c >> 16) & 0xFF);
    const b: f32 = @floatFromInt((c >> 8) & 0xFF);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// `c` with its RGB scaled by `k` (0..1); alpha kept.
pub fn shade(c: u32, k: f32) u32 {
    const kk = std.math.clamp(k, 0, 1);
    return lerp(c & 0xFF, c, kk) | (c & 0xFF);
}

const testing = std.testing;

test "lerp blends each channel" {
    try testing.expectEqual(0x000000FF, lerp(0x000000FF, 0xFFFFFFFF, 0));
    try testing.expectEqual(0xFFFFFFFF, lerp(0x000000FF, 0xFFFFFFFF, 1));
    try testing.expectEqual(0x808080FF, lerp(0x000000FF, 0xFFFFFFFF, 0.5));
}

test "ground runs through the stops and clamps" {
    try testing.expectEqual(ground_stops[0], ground(-1));
    try testing.expectEqual(ground_stops[0], ground(0));
    try testing.expectEqual(teal, ground(1.0 / 3.0));
    try testing.expectEqual(ground_stops[3], ground(1));
    try testing.expectEqual(ground_stops[3], ground(7));
}

test "luma weighs green most, ignores alpha" {
    try testing.expectEqual(0, luma(0x000000FF));
    try testing.expectApproxEqAbs(255, luma(0xFFFFFF00), 1e-3);
    try testing.expect(luma(0x00FF00FF) > luma(0xFF0000FF));
}

test "shade darkens RGB, keeps alpha" {
    try testing.expectEqual(0x404020FF, shade(0x808040FF, 0.5));
    try testing.expectEqual(0x000000FF, shade(0xFFFFFFFF, 0));
    try testing.expectEqual(0x12345678, shade(0x12345678, 1));
}

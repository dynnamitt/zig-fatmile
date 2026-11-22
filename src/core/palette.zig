//! Colours as 0xRRGGBBAA, from the tech-trio.svg palette, so modules that
//! never import raylib can still name them. web/shell.html repeats the first three.
const std = @import("std");

pub const background: u32 = 0x0E1414FF; // near-black teal
pub const teal: u32 = 0x2E7E7EFF;
pub const sand: u32 = 0xC8A878FF;

/// Partition lines between hexes.
pub const line: u32 = 0x000000FF;

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
        const c: u32 = @intFromFloat(@round(ca + (cb - ca) * t));
        out |= c << shift;
    }
    return out;
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

test "shade darkens RGB, keeps alpha" {
    try testing.expectEqual(0x404020FF, shade(0x808040FF, 0.5));
    try testing.expectEqual(0x000000FF, shade(0xFFFFFFFF, 0));
    try testing.expectEqual(0x12345678, shade(0x12345678, 1));
}

//! The sky: its colour by view direction, the sun and the moon, and the
//! distance fog that fades the terrain into the horizon, so chunks never
//! pop in at the edge of the loaded area. The sky shader (`render/Sky.zig`)
//! and the terrain shader (`render/terrain.zig`) repeat `color` and `fog`;
//! keep them in step.
const std = @import("std");
const Vec3 = @import("vec.zig").Vec3;
const palette = @import("palette.zig");

/// Unit vector towards the sky at compass bearing `azimuth` and `elevation`
/// above the horizon, both in degrees. Bearing 0 is +x, 90 is +z.
pub fn direction(azimuth: f32, elevation: f32) Vec3 {
    const az = std.math.degreesToRadians(azimuth);
    const el = std.math.degreesToRadians(elevation);
    return .{ .x = @cos(el) * @cos(az), .y = @sin(el), .z = @cos(el) * @sin(az) };
}

/// Towards the sun: low enough to show at the top of the view when you look
/// at the horizon (half the 70° field of view is 35°). The terrain's baked
/// light comes from here too (`ChunkMesh.Style.sun`).
pub const sun = direction(32, 30);
/// Angular radius of the sun's disc, in degrees.
pub const sun_radius: f32 = 2.2;
/// Towards the moon: low, well round from the sun.
pub const moon = direction(-110, 18);
pub const moon_radius: f32 = 1.4;
/// The moon's dark part is a disc this far (in moon radii) off its centre,
/// towards the horizon away from the sun, which leaves a crescent.
pub const moon_shadow_offset: f32 = 0.45;

/// Centre of the disc that hides the moon's dark part: the moon's own
/// direction moved along the sky, away from the sun, by
/// `moon_shadow_offset` moon radii.
/// @returns {Vec3} unit vector.
pub fn moonShadow() Vec3 {
    // At the moon, the sky direction pointing away from the sun.
    const away = moon.scale(moon.dot(sun)).sub(sun).normalize();
    const offset = std.math.degreesToRadians(moon_radius) * moon_shadow_offset;
    return moon.add(away.scale(offset)).normalize();
}

/// Gradient shape: `t = pow(dir.y, horizon_falloff)` runs from the horizon
/// haze (0) through `palette.sky_mid` (0.5) to the zenith (1). Below 1 the
/// haze band is thin.
pub const horizon_falloff: f32 = 0.45;

/// Fog by horizontal distance from the eye, in metres: none up to
/// `fog_start`, full sky-horizon colour from `fog_end`. `fog_end` stays
/// inside the area that is always loaded round the player (tested below).
pub const fog_start: f32 = 40;
pub const fog_end: f32 = 110;

/// Sky colour (no sun or moon) looking along unit vector `dir`. Below the
/// horizon it is the horizon colour, which is also the fog colour, so
/// fogged terrain meets the sky without a seam.
/// @param dir {Vec3} view direction, unit length.
/// @returns {u32} 0xRRGGBBAA.
pub fn color(dir: Vec3) u32 {
    const t = std.math.pow(f32, std.math.clamp(dir.y, 0, 1), horizon_falloff);
    return if (t < 0.5)
        palette.lerp(palette.sky_horizon, palette.sky_mid, t * 2)
    else
        palette.lerp(palette.sky_mid, palette.sky_zenith, t * 2 - 1);
}

/// How much fog covers a point `distance` metres away (horizontally).
/// @returns {f32} 0 (clear) to 1 (sky colour), smoothstep between.
pub fn fog(distance: f32) f32 {
    const t = std.math.clamp((distance - fog_start) / (fog_end - fog_start), 0, 1);
    return t * t * (3 - 2 * t);
}

const testing = std.testing;
const world = @import("world.zig");
const Hex = @import("Hex.zig");
const streaming = @import("streaming.zig");

test "direction: bearing and elevation" {
    const d = direction(90, 30);
    try testing.expectApproxEqAbs(1, d.length(), 1e-6);
    try testing.expectApproxEqAbs(0.5, d.y, 1e-6);
    try testing.expectApproxEqAbs(0, d.x, 1e-6);
    try testing.expect(d.z > 0);
}

test "sun and moon are up, apart, and in view of a level camera" {
    for ([_]Vec3{ sun, moon }) |d| {
        try testing.expect(d.y > 0);
        // Inside the vertical half field of view (35°) of a level camera.
        try testing.expect(d.y < @sin(std.math.degreesToRadians(35.0)));
    }
    try testing.expect(sun.dot(moon) < 0);
}

test "moonShadow: off the moon by the offset, on the side away from the sun" {
    const sh = moonShadow();
    try testing.expectApproxEqAbs(1, sh.length(), 1e-6);
    try testing.expect(sh.dot(sun) < moon.dot(sun));
    const angle = std.math.radiansToDegrees(std.math.acos(sh.dot(moon)));
    try testing.expectApproxEqAbs(moon_radius * moon_shadow_offset, angle, 0.05);
}

test "color: horizon haze at and below the horizon, zenith straight up" {
    try testing.expectEqual(palette.sky_horizon, color(.{ .x = 1, .y = 0, .z = 0 }));
    try testing.expectEqual(palette.sky_horizon, color(.{ .x = 0, .y = -1, .z = 0 }));
    try testing.expectEqual(palette.sky_zenith, color(Vec3.up));
}

test "fog: clear near, full far, rising in between" {
    try testing.expectEqual(0, fog(0));
    try testing.expectEqual(0, fog(fog_start));
    try testing.expectEqual(1, fog(fog_end));
    try testing.expectEqual(1, fog(1e6));
    var last: f32 = 0;
    var d: f32 = fog_start;
    while (d <= fog_end) : (d += 1) {
        try testing.expect(fog(d) >= last);
        last = fog(d);
    }
}

test "fog is full before the edge of the loaded area" {
    // TerrainStream loads every chunk within `streaming.chunk_range.load` steps of
    // the player's chunk. From anywhere in chunk 0,0, every point within
    // `fog_end` must lie in such a chunk, or bare edges would show through.
    const spacing = world.hex_size * @sqrt(3.0);
    const reach: f32 = @as(f32, @floatFromInt(world.chunk_radius + 2)) * spacing;
    const step = world.hex_size / 2;
    const dirs = 48;
    var x: f32 = -reach;
    while (x <= reach) : (x += step) {
        var z: f32 = -reach;
        while (z <= reach) : (z += step) {
            const here = Hex.fromWorld(x, z, world.hex_size).toLowerRes(world.chunk_radius);
            if (!here.eql(Hex.zero)) continue;
            for (0..dirs) |i| {
                const a = std.math.tau * @as(f32, @floatFromInt(i)) / dirs;
                const px = x + fog_end * @cos(a);
                const pz = z + fog_end * @sin(a);
                const there = Hex.fromWorld(px, pz, world.hex_size).toLowerRes(world.chunk_radius);
                try testing.expect(Hex.distance(here, there) <= streaming.chunk_range.load);
            }
        }
    }
}

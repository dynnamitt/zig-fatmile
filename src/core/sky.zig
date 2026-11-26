//! The sky's settings: the sun and the moon, the gradient's shape, and the
//! distance fog that fades the terrain into the horizon, so chunks never
//! pop in at the edge of the loaded area. The colours are `palette.sky_*`.
//! The formulas live in the shaders that use these (`render/Sky.zig`,
//! `render/terrain.zig`); `hiddenByFog` is the one the CPU needs, for culling.
const std = @import("std");
const Vec3 = @import("vec.zig").Vec3;
const Aabb = @import("Aabb.zig");
const motion = @import("motion.zig");
const streaming = @import("streaming.zig");

/// Unit vector towards the sky at compass bearing `azimuth` and `elevation`
/// above the horizon, both in degrees. Bearing 0 is +x, 90 is +z: the
/// player's look direction (`motion.lookDir`) at yaw 90° − bearing.
pub fn direction(azimuth: f32, elevation: f32) Vec3 {
    return motion.lookDir(std.math.degreesToRadians(90 - azimuth), std.math.degreesToRadians(elevation));
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

/// Gradient shape: `t = pow(dir.y, horizon_falloff)` runs from
/// `palette.sky_horizon` (0) through `sky_mid` (0.5) to `sky_zenith` (1).
/// Below 1 the haze band is thin. At and below the horizon the sky is
/// `sky_horizon`, the fog colour, so fogged terrain meets it without a seam.
pub const horizon_falloff: f32 = 0.45;

/// Fog by horizontal distance from the eye, in metres: none up to
/// `fog_start`, smoothstep to the full horizon colour at `fog_end`.
pub const fog_start: f32 = 40;
pub const fog_end: f32 = 110;

comptime {
    // Bare edges of the loaded area must never show through.
    std.debug.assert(fog_end <= streaming.min_loaded_radius);
}

/// Whether the fog covers all of `box` seen from `eye`: it lies `fog_end`
/// or more away horizontally and no higher than the eye. A fogged box
/// above the eye isn't hidden: against the sky above the horizon, which is
/// darker than the haze, its silhouette still shows.
pub fn hiddenByFog(box: Aabb, eye: Vec3) bool {
    return box.max.y <= eye.y and box.distanceXz(eye.x, eye.z) >= fog_end;
}

const testing = std.testing;

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

test "hiddenByFog: far and below the eye only" {
    const eye: Vec3 = .{ .x = 0, .y = 10, .z = 0 };
    const far = Aabb.ofPositions(&.{ fog_end + 1, 0, 0, fog_end + 20, 9, 5 });
    try testing.expect(hiddenByFog(far, eye));
    var tall = far;
    tall.max.y = 11;
    try testing.expect(!hiddenByFog(tall, eye));
    const near = Aabb.ofPositions(&.{ fog_end - 1, 0, 0, fog_end + 20, 9, 5 });
    try testing.expect(!hiddenByFog(near, eye));
}

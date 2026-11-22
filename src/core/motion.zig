//! First-person look and walk maths. Yaw 0 looks along +z, positive yaw turns
//! left (towards +x); pitch is up from the horizon, in radians.
const std = @import("std");
const Vec3 = @import("vec.zig").Vec3;

/// Pitch stops short of straight up/down, where yaw would be undefined.
pub const max_pitch: f32 = 1.5;

pub fn clampPitch(pitch: f32) f32 {
    return std.math.clamp(pitch, -max_pitch, max_pitch);
}

/// Unit view direction.
pub fn lookDir(yaw: f32, pitch: f32) Vec3 {
    return .{ .x = @cos(pitch) * @sin(yaw), .y = @sin(pitch), .z = @cos(pitch) * @cos(yaw) };
}

/// Horizontal velocity (x, z) for walk input `right`, `forward` (each -1..1,
/// a stick or keys) at `speed`. Diagonals are no faster than straight lines.
pub fn walkVelocity(yaw: f32, right: f32, forward: f32, speed: f32) [2]f32 {
    var r = right;
    var f = forward;
    const len = @sqrt(r * r + f * f);
    if (len > 1) {
        r /= len;
        f /= len;
    }
    // forward = (sin yaw, cos yaw), right = forward × up = (-cos yaw, sin yaw)
    const s = @sin(yaw);
    const c = @cos(yaw);
    return .{ (f * s - r * c) * speed, (f * c + r * s) * speed };
}

/// Moves `current` towards `target`, closing the fraction `1 - e^(-rate·dt)`
/// of the gap: frame-rate independent exponential smoothing.
pub fn approach(current: f32, target: f32, rate: f32, dt: f32) f32 {
    return target + (current - target) * @exp(-rate * dt);
}

const testing = std.testing;

test "lookDir: yaw 0 is +z, quarter turn is +x, pitch looks up" {
    const eps = 1e-6;
    const fwd = lookDir(0, 0);
    try testing.expectApproxEqAbs(1, fwd.z, eps);
    try testing.expectApproxEqAbs(1, lookDir(std.math.pi / 2.0, 0).x, eps);
    try testing.expectApproxEqAbs(1, lookDir(0.3, std.math.pi / 2.0).y, eps);
    try testing.expectApproxEqAbs(1, lookDir(1.1, -0.4).length(), eps);
}

test "walkVelocity: forward follows yaw, right is forward × up, diagonals capped" {
    const eps = 1e-5;
    const f = walkVelocity(0, 0, 1, 2);
    try testing.expectApproxEqAbs(0, f[0], eps);
    try testing.expectApproxEqAbs(2, f[1], eps);
    const yaw: f32 = 0.7;
    const r = walkVelocity(yaw, 1, 0, 1);
    const right = lookDir(yaw, 0).cross(Vec3.up);
    try testing.expectApproxEqAbs(right.x, r[0], eps);
    try testing.expectApproxEqAbs(right.z, r[1], eps);
    const d = walkVelocity(yaw, 1, 1, 3);
    try testing.expectApproxEqAbs(3, @sqrt(d[0] * d[0] + d[1] * d[1]), eps);
    const slow = walkVelocity(yaw, 0.3, 0.4, 2); // half-tilted stick: half speed
    try testing.expectApproxEqAbs(1, @sqrt(slow[0] * slow[0] + slow[1] * slow[1]), eps);
}

test "clampPitch" {
    try testing.expectEqual(max_pitch, clampPitch(3));
    try testing.expectEqual(-max_pitch, clampPitch(-3));
    try testing.expectEqual(0.2, clampPitch(0.2));
}

test "approach: converges, never overshoots, same at any step size" {
    try testing.expectEqual(5, approach(5, 5, 10, 0.1));
    const one = approach(0, 1, 4, 0.5);
    try testing.expect(one > 0 and one < 1);
    var two: f32 = 0;
    for (0..2) |_| two = approach(two, 1, 4, 0.25);
    try testing.expectApproxEqAbs(one, two, 1e-6);
    try testing.expectApproxEqAbs(1, approach(0, 1, 50, 1), 1e-6);
}

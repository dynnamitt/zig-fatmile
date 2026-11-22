//! 3D vector, world space: y is up, metres. `extern` so chunk files can be
//! read as slices of it without copying (`Chunk.zig`); a file's own struct
//! can't be extern, hence the wrapper declaration.
pub const Vec3 = extern struct {
    x: f32,
    y: f32,
    z: f32,

    pub const zero: Vec3 = .{ .x = 0, .y = 0, .z = 0 };
    pub const up: Vec3 = .{ .x = 0, .y = 1, .z = 0 };

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn length(a: Vec3) f32 {
        return @sqrt(a.dot(a));
    }

    /// `a` scaled to length 1, or zero if `a` is zero.
    pub fn normalize(a: Vec3) Vec3 {
        const len = a.length();
        return if (len > 0) a.scale(1 / len) else zero;
    }

    /// `a` at `t` = 0, `b` at `t` = 1.
    pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
        return a.add(b.sub(a).scale(t));
    }
};

const std = @import("std");

test "layout is three packed f32s" {
    try std.testing.expectEqual(12, @sizeOf(Vec3));
}

test "cross follows the right-hand rule" {
    const x: Vec3 = .{ .x = 1, .y = 0, .z = 0 };
    const z: Vec3 = .{ .x = 0, .y = 0, .z = 1 };
    try std.testing.expectEqual(Vec3.up, z.cross(x));
    try std.testing.expectEqual(Vec3.up.scale(-1), x.cross(z));
}

test "normalize, length, dot, lerp" {
    const v: Vec3 = .{ .x = 3, .y = 0, .z = 4 };
    try std.testing.expectEqual(5, v.length());
    try std.testing.expectApproxEqAbs(1, v.normalize().length(), 1e-6);
    try std.testing.expectEqual(Vec3.zero, Vec3.zero.normalize());
    try std.testing.expectEqual(25, v.dot(v));
    try std.testing.expectEqual(Vec3{ .x = 1.5, .y = 0, .z = 2 }, Vec3.zero.lerp(v, 0.5));
    try std.testing.expectEqual(Vec3{ .x = 2, .y = -1, .z = 3 }, v.sub(.{ .x = 1, .y = 1, .z = 1 }));
}

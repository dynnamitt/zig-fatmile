//! The six planes of a camera's view volume, for culling boxes before they
//! are drawn. Built from the camera's view-projection matrix (Gribb and
//! Hartmann's plane extraction), so it matches what the GPU clips.
const std = @import("std");
const Vec3 = @import("vec.zig").Vec3;
const Aabb = @import("Aabb.zig");
const Frustum = @This();

/// A plane `n·p + d = 0`; points with `n·p + d >= 0` are on the inside.
pub const Plane = struct { n: Vec3, d: f32 };

/// Left, right, bottom, top, near, far.
planes: [6]Plane,

/// The frustum of a view-projection matrix.
/// @param rows {[4][4]f32} the matrix by rows, as it multiplies a column
///   vector: clip = M·(x, y, z, 1). OpenGL's clip volume, -w ≤ x, y, z ≤ w.
/// @returns {Frustum} its planes; they need not be normalised for `touches`.
pub fn fromMatrix(rows: [4][4]f32) Frustum {
    const w = rows[3];
    var f: Frustum = undefined;
    for (0..3) |axis| {
        for (0..2) |side| {
            const sign: f32 = if (side == 0) 1 else -1;
            var p: [4]f32 = undefined;
            for (&p, w, rows[axis]) |*c, wc, ac| c.* = wc + sign * ac;
            f.planes[axis * 2 + side] = .{ .n = .{ .x = p[0], .y = p[1], .z = p[2] }, .d = p[3] };
        }
    }
    return f;
}

/// Whether box `b` may be in view: false only when it lies wholly outside
/// one plane. A box near a frustum corner can pass while unseen; that only
/// costs a draw. An empty box is never in view.
pub fn touches(f: Frustum, b: Aabb) bool {
    if (b.isEmpty()) return false;
    for (f.planes) |pl| {
        // The box corner furthest along the plane's normal.
        const far: Vec3 = .{
            .x = if (pl.n.x >= 0) b.max.x else b.min.x,
            .y = if (pl.n.y >= 0) b.max.y else b.min.y,
            .z = if (pl.n.z >= 0) b.max.z else b.min.z,
        };
        if (pl.n.dot(far) + pl.d < 0) return false;
    }
    return true;
}

const testing = std.testing;

/// OpenGL's perspective matrix (gluPerspective) for a camera at the origin
/// looking down -z, 90° vertical field of view, square aspect.
fn testFrustum() Frustum {
    const near: f32 = 0.1;
    const far: f32 = 100;
    return fromMatrix(.{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, -(far + near) / (far - near), -2 * far * near / (far - near) },
        .{ 0, 0, -1, 0 },
    });
}

fn box(x: f32, y: f32, z: f32, half: f32) Aabb {
    return .{ .min = .{ .x = x - half, .y = y - half, .z = z - half }, .max = .{ .x = x + half, .y = y + half, .z = z + half } };
}

test "boxes ahead are in view; behind, aside and past the far plane are not" {
    const f = testFrustum();
    try testing.expect(f.touches(box(0, 0, -10, 1)));
    try testing.expect(!f.touches(box(0, 0, 10, 1)));
    // 90° field of view: at depth 10 the view is 10 m to each side.
    try testing.expect(f.touches(box(9, 0, -10, 0.5)));
    try testing.expect(!f.touches(box(13, 0, -10, 1)));
    try testing.expect(!f.touches(box(0, -13, -10, 1)));
    try testing.expect(!f.touches(box(0, 0, -200, 1)));
    try testing.expect(!f.touches(Aabb.empty));
}

test "a box round the camera, or straddling a plane, is in view" {
    const f = testFrustum();
    try testing.expect(f.touches(box(0, 0, 0, 5)));
    try testing.expect(f.touches(box(10, 0, -10, 1)));
    try testing.expect(f.touches(box(0, 0, -100, 1)));
}

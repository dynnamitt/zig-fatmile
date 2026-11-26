//! Axis-aligned bounding box in world space, for culling.
const std = @import("std");
const Vec3 = @import("vec.zig").Vec3;
const Aabb = @This();

min: Vec3,
max: Vec3,

/// Holds nothing; `include` and `join` grow it.
pub const empty: Aabb = .{
    .min = .{ .x = std.math.inf(f32), .y = std.math.inf(f32), .z = std.math.inf(f32) },
    .max = .{ .x = -std.math.inf(f32), .y = -std.math.inf(f32), .z = -std.math.inf(f32) },
};

/// Whether the box holds no point (it is `empty` or was built inside out).
pub fn isEmpty(b: Aabb) bool {
    return b.min.x > b.max.x or b.min.y > b.max.y or b.min.z > b.max.z;
}

/// `b` grown to hold point `p`.
pub fn include(b: Aabb, p: Vec3) Aabb {
    return .{
        .min = .{ .x = @min(b.min.x, p.x), .y = @min(b.min.y, p.y), .z = @min(b.min.z, p.z) },
        .max = .{ .x = @max(b.max.x, p.x), .y = @max(b.max.y, p.y), .z = @max(b.max.z, p.z) },
    };
}

/// The smallest box holding both `a` and `b`.
pub fn join(a: Aabb, b: Aabb) Aabb {
    if (b.isEmpty()) return a;
    return a.include(b.min).include(b.max);
}

/// Horizontal (x, z) distance from point `x`, `z` to the box; 0 above or
/// below it.
pub fn distanceXz(b: Aabb, x: f32, z: f32) f32 {
    const dx = @max(b.min.x - x, 0, x - b.max.x);
    const dz = @max(b.min.z - z, 0, z - b.max.z);
    return @sqrt(dx * dx + dz * dz);
}

/// The box round `positions`, 3 floats per point.
/// @param positions {[]const f32} x, y, z per point; `empty` if none.
/// @returns {Aabb} the bounds.
pub fn ofPositions(positions: []const f32) Aabb {
    var b = empty;
    var i: usize = 0;
    while (i + 3 <= positions.len) : (i += 3) b = b.include(.{ .x = positions[i], .y = positions[i + 1], .z = positions[i + 2] });
    return b;
}

const testing = std.testing;

test "empty grows to its points" {
    try testing.expect(empty.isEmpty());
    const b = ofPositions(&.{ 1, 2, 3, -1, 5, 0 });
    try testing.expect(!b.isEmpty());
    try testing.expectEqual(Vec3{ .x = -1, .y = 2, .z = 0 }, b.min);
    try testing.expectEqual(Vec3{ .x = 1, .y = 5, .z = 3 }, b.max);
    try testing.expect(ofPositions(&.{}).isEmpty());
}

test "distanceXz: zero over the box, straight or diagonal outside it" {
    const b = ofPositions(&.{ 0, 0, 0, 2, 5, 2 });
    try testing.expectEqual(0, b.distanceXz(1, 1));
    try testing.expectEqual(3, b.distanceXz(5, 1));
    try testing.expectEqual(5, b.distanceXz(-3, -4));
}

test "join holds both, and empty joins to the other" {
    const a = ofPositions(&.{ 0, 0, 0, 1, 1, 1 });
    const b = ofPositions(&.{ 2, -1, 0, 3, 0, 1 });
    const j = a.join(b);
    try testing.expectEqual(Vec3{ .x = 0, .y = -1, .z = 0 }, j.min);
    try testing.expectEqual(Vec3{ .x = 3, .y = 1, .z = 1 }, j.max);
    try testing.expectEqual(a, empty.join(a));
    try testing.expectEqual(a, a.join(empty));
}

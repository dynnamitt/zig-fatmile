//! The ground rule: where the walker stands and which steps it may take.
//!
//! The ground is the terrain's own triangles: a hex face is flat at the cell's
//! height, and a gap quad (or junction tri) between cells is interpolated
//! across, exactly as it is drawn. A step that climbs steeper than
//! `max_climb` (rise over run) is refused; going down is always allowed, so
//! the walker can always slide down what it cannot climb (issue #1).
const std = @import("std");
const Vec3 = @import("vec.zig").Vec3;
const Tri = @import("Chunk.zig").Tri;

/// Ground height lookup, so the rule runs on terrain, test planes or
/// anything else. `heightAt` is null where there is no ground (off the
/// world, or a chunk that isn't loaded): the walker never steps there.
pub const Ground = struct {
    ctx: *const anyopaque,
    heightAtFn: *const fn (ctx: *const anyopaque, x: f32, z: f32) ?f32,

    pub fn heightAt(g: Ground, x: f32, z: f32) ?f32 {
        return g.heightAtFn(g.ctx, x, z);
    }
};

/// Points this close outside a triangle (barycentric weight) still count as
/// on it, so float error on a shared edge never opens a crack between tris.
const edge_tolerance = 1e-4;

/// Height of `t` above world point `x`, `z`, or null if the point is outside
/// the triangle seen from above (or the triangle is edge-on).
pub fn heightInTri(t: Tri, x: f32, z: f32) ?f32 {
    const e1x = t.b.x - t.a.x;
    const e1z = t.b.z - t.a.z;
    const e2x = t.c.x - t.a.x;
    const e2z = t.c.z - t.a.z;
    const det = e1x * e2z - e2x * e1z;
    if (@abs(det) < 1e-9) return null;
    const px = x - t.a.x;
    const pz = z - t.a.z;
    const u = (px * e2z - e2x * pz) / det; // weight of b
    const v = (e1x * pz - px * e1z) / det; // weight of c
    if (u < -edge_tolerance or v < -edge_tolerance or u + v > 1 + edge_tolerance) return null;
    return t.a.y + u * (t.b.y - t.a.y) + v * (t.c.y - t.a.y);
}

/// Whether a step that moves `run` metres sideways from height `from_y` to
/// `to_y` may be taken: never steeper uphill than `max_climb`, any slope down.
pub fn stepAllowed(from_y: f32, to_y: f32, run: f32, max_climb: f32) bool {
    return to_y - from_y <= max_climb * run;
}

/// Moves `pos` (standing on the ground) by `dx`, `dz` and puts it on the
/// ground there. A refused step tries each axis alone, so the walker slides
/// along a cliff instead of sticking to it; if both are refused it stays.
pub fn walk(g: Ground, pos: Vec3, dx: f32, dz: f32, max_climb: f32) Vec3 {
    const tries = [_][2]f32{ .{ dx, dz }, .{ dx, 0 }, .{ 0, dz } };
    for (tries) |d| {
        const run = @sqrt(d[0] * d[0] + d[1] * d[1]);
        if (run == 0) continue;
        const x = pos.x + d[0];
        const z = pos.z + d[1];
        const y = g.heightAt(x, z) orelse continue;
        if (stepAllowed(pos.y, y, run, max_climb)) return .{ .x = x, .y = y, .z = z };
    }
    return pos;
}

const testing = std.testing;

/// Test ground: a step function along x. Level at 0 for x < 0, a ramp of
/// slope `ramp` from x = 0 to x = 1, level beyond; nothing past |z| > 10.
const Ramp = struct {
    ramp: f32,

    fn heightAt(ctx: *const anyopaque, x: f32, z: f32) ?f32 {
        const self: *const Ramp = @ptrCast(@alignCast(ctx));
        if (@abs(z) > 10) return null;
        return self.ramp * std.math.clamp(x, 0, 1);
    }

    fn ground(self: *const Ramp) Ground {
        return .{ .ctx = self, .heightAtFn = heightAt };
    }
};

test "heightInTri interpolates inside and refuses outside" {
    const t: Tri = .{
        .a = .{ .x = 0, .y = 0, .z = 0 },
        .b = .{ .x = 1, .y = 1, .z = 0 },
        .c = .{ .x = 0, .y = 2, .z = 1 },
    };
    try testing.expectApproxEqAbs(0, heightInTri(t, 0, 0).?, 1e-6);
    try testing.expectApproxEqAbs(1, heightInTri(t, 1, 0).?, 1e-6);
    try testing.expectApproxEqAbs(2, heightInTri(t, 0, 1).?, 1e-6);
    try testing.expectApproxEqAbs(0.75, heightInTri(t, 0.25, 0.25).?, 1e-6);
    try testing.expectApproxEqAbs(1.5, heightInTri(t, 0.5, 0.5).?, 1e-6); // on the b–c edge
    try testing.expectEqual(null, heightInTri(t, 0.6, 0.6));
    try testing.expectEqual(null, heightInTri(t, -0.1, 0.5));
    // Winding doesn't matter.
    try testing.expectApproxEqAbs(0.75, heightInTri(.{ .a = t.a, .b = t.c, .c = t.b }, 0.25, 0.25).?, 1e-6);
    // Edge-on (vertical) triangles have no height.
    const wall: Tri = .{ .a = t.a, .b = .{ .x = 1, .y = 0, .z = 0 }, .c = .{ .x = 1, .y = 5, .z = 0 } };
    try testing.expectEqual(null, heightInTri(wall, 0.5, 0));
}

test "stepAllowed: capped uphill, any downhill" {
    try testing.expect(stepAllowed(0, 0, 0.1, 1));
    try testing.expect(stepAllowed(0, 0.1, 0.1, 1)); // exactly max_climb
    try testing.expect(!stepAllowed(0, 0.11, 0.1, 1));
    try testing.expect(stepAllowed(5, 0, 0.1, 1)); // a cliff down is fine
}

test "walk climbs a gentle ramp and stands on it" {
    const r: Ramp = .{ .ramp = 0.5 };
    const p = walk(r.ground(), .{ .x = 0.25, .y = 0.125, .z = 0 }, 0.1, 0, 1);
    try testing.expectApproxEqAbs(0.35, p.x, 1e-6);
    try testing.expectApproxEqAbs(0.175, p.y, 1e-6);
}

test "walk refuses a steep ramp but slides along it, and down it" {
    const r: Ramp = .{ .ramp = 3 };
    const start: Vec3 = .{ .x = 0, .y = 0, .z = 0 };
    try testing.expectEqual(start, walk(r.ground(), start, 0.1, 0, 1));
    // Diagonal into the cliff: the x part is refused, the z part is kept.
    const slid = walk(r.ground(), start, 0.1, 0.1, 1);
    try testing.expectEqual(Vec3{ .x = 0, .y = 0, .z = 0.1 }, slid);
    // From the top, stepping down the same slope is allowed.
    const top: Vec3 = .{ .x = 1, .y = 3, .z = 0 };
    const down = walk(r.ground(), top, -0.1, 0, 1);
    try testing.expectApproxEqAbs(2.7, down.y, 1e-5);
}

test "walk never leaves the ground" {
    const r: Ramp = .{ .ramp = 0 };
    const edge: Vec3 = .{ .x = 0, .y = 0, .z = 10 };
    try testing.expectEqual(edge, walk(r.ground(), edge, 0, 0.1, 1));
    try testing.expectEqual(edge, walk(r.ground(), edge, 0, 0, 1)); // no move
}

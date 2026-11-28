//! The loaded part of the world: parsed chunks by coordinate, and the ground
//! height under any point on them. Holds views only; whoever loaded the
//! chunk bytes keeps them alive until `remove`.
const std = @import("std");
const Hex = @import("Hex.zig");
const Chunk = @import("Chunk.zig");
const ground = @import("ground.zig");
const Vec3 = @import("vec.zig").Vec3;
const Terrain = @This();

// raycast: march in ray_step (m) samples, then halve the last interval
// ray_refine times (0.1 m / 2^12 ≈ 0.02 mm).
const ray_step = 0.1;
const ray_refine = 12;

const Loaded = struct {
    chunk: Chunk,
    /// Cell hex → index into `chunk.cells`.
    cells: std.AutoHashMapUnmanaged(Hex, u32) = .empty,
};

allocator: std.mem.Allocator,
chunk_radius: u32,
hex_size: f32,
chunks: std.AutoHashMapUnmanaged(Hex, Loaded) = .empty,

pub fn init(allocator: std.mem.Allocator, chunk_radius: u32, hex_size: f32) Terrain {
    return .{ .allocator = allocator, .chunk_radius = chunk_radius, .hex_size = hex_size };
}

pub fn deinit(t: *Terrain) void {
    var it = t.chunks.valueIterator();
    while (it.next()) |l| l.cells.deinit(t.allocator);
    t.chunks.deinit(t.allocator);
}

/// Adds `chunk` (replacing any chunk at its coordinate).
pub fn insert(t: *Terrain, chunk: Chunk) error{OutOfMemory}!void {
    var loaded: Loaded = .{ .chunk = chunk };
    errdefer loaded.cells.deinit(t.allocator);
    try loaded.cells.ensureTotalCapacity(t.allocator, @intCast(chunk.cells.len));
    for (chunk.cells, 0..) |c, i| loaded.cells.putAssumeCapacity(c.hex(), @intCast(i));
    t.remove(chunk.coord);
    try t.chunks.put(t.allocator, chunk.coord, loaded);
}

pub fn remove(t: *Terrain, coord: Hex) void {
    var kv = t.chunks.fetchRemove(coord) orelse return;
    kv.value.cells.deinit(t.allocator);
}

/// The chunk coordinate that world point `x`, `z` falls in.
pub fn chunkAt(t: Terrain, x: f32, z: f32) Hex {
    return Hex.fromWorld(x, z, t.hex_size).toLowerRes(t.chunk_radius);
}

/// Ground height at world `x`, `z`, or null off the loaded terrain.
pub fn heightAt(t: *const Terrain, x: f32, z: f32) ?f32 {
    // The point lies in its hex's full hexagon. That area is covered by the
    // hex's face, half of each gap quad round it and the junction tris at
    // its corners, which the hex or one of its neighbours owns.
    const h = Hex.fromWorld(x, z, t.hex_size);
    const nb = h.neighbors();
    for ([_]Hex{h} ++ nb) |owner| {
        for (t.cellTris(owner) orelse continue) |tri| {
            if (ground.heightInTri(tri, x, z)) |y| return y;
        }
    }
    return null;
}

/// Triangles of loaded cell `h` (face first, `Chunk.face_tris`), or null.
fn cellTris(t: *const Terrain, h: Hex) ?[]align(1) const Chunk.Tri {
    const loaded = t.chunks.getPtr(h.toLowerRes(t.chunk_radius)) orelse return null;
    const i = loaded.cells.get(h) orelse return null;
    return loaded.chunk.cellTris(i);
}

/// A loaded cell's height (its face's), or null if its chunk isn't loaded.
pub fn cellHeight(t: *const Terrain, h: Hex) ?f32 {
    const loaded = t.chunks.getPtr(h.toLowerRes(t.chunk_radius)) orelse return null;
    const i = loaded.cells.get(h) orelse return null;
    return loaded.chunk.cells[i].height;
}

/// Cell whose flat top (its face, not a gap or junction) covers a world
/// point. Its height is that cell's `height`.
/// @param x {f32} world x, m.
/// @param z {f32} world z, m.
/// @returns {?Hex} the cell, or null over a gap, a junction or unloaded ground.
pub fn faceAt(t: *const Terrain, x: f32, z: f32) ?Hex {
    // A face lies inside its own hex's hexagon, so only `h` can own it.
    const h = Hex.fromWorld(x, z, t.hex_size);
    const face = (t.cellTris(h) orelse return null)[0..Chunk.face_tris];
    for (face) |tri| if (ground.heightInTri(tri, x, z) != null) return h;
    return null;
}

/// First point where a ray meets the ground. Unloaded ground isn't hit.
/// Samples every `ray_step` m, so a ridge thinner than that can be missed.
/// @param origin {Vec3} where the ray starts.
/// @param dir {Vec3} its direction, unit length.
/// @param max_dist {f32} how far to look, m: finite, at least 0.
/// @returns {?Vec3} the hit point, or null within `max_dist`.
pub fn raycast(t: *const Terrain, origin: Vec3, dir: Vec3, max_dist: f32) ?Vec3 {
    std.debug.assert(max_dist >= 0 and std.math.isFinite(max_dist));
    const steps: usize = @intFromFloat(@ceil(max_dist / ray_step));
    const ray: Ray = .{ .t = t, .origin = origin, .dir = dir };
    var prev: f32 = 0;
    for (0..steps + 1) |i| {
        const d = @min(@as(f32, @floatFromInt(i)) * ray_step, max_dist);
        defer prev = d;
        if (!ray.belowAt(d)) continue;
        // Ground between prev (above) and d (below; both 0 if the origin is
        // under the ground): bisect.
        var lo = prev;
        var hi = d;
        for (0..ray_refine) |_| {
            const mid = (lo + hi) / 2;
            if (ray.belowAt(mid)) hi = mid else lo = mid;
        }
        return ray.at(hi);
    }
    return null;
}

const Ray = struct {
    t: *const Terrain,
    origin: Vec3,
    dir: Vec3,

    fn at(r: Ray, d: f32) Vec3 {
        return r.origin.add(r.dir.scale(d));
    }

    /// Whether the point `d` m along is at or under the ground (false off
    /// the loaded terrain).
    fn belowAt(r: Ray, d: f32) bool {
        const p = r.at(d);
        const y = r.t.heightAt(p.x, p.z) orelse return false;
        return p.y <= y;
    }
};

/// This terrain as the ground rule's height lookup. `t` must stay put.
pub fn asGround(t: *const Terrain) ground.Ground {
    return .of(Terrain, t);
}

const testing = std.testing;
const test_data = @import("test_data.zig");
const world = @import("world.zig");

fn testTerrain() !Terrain {
    var t: Terrain = .init(testing.allocator, world.chunk_radius, world.hex_size);
    try t.insert(try Chunk.parse(test_data.chunk_bytes));
    return t;
}

test "a cell's face is flat at its height" {
    var t = try testTerrain();
    defer t.deinit();
    const chunk = t.chunks.get(.zero).?.chunk;
    for (chunk.cells) |c| {
        const w = c.hex().toWorld(t.hex_size);
        try testing.expectEqual(c.height, t.heightAt(w[0], w[1]).?);
        // Most of the way to a corner is still on the face.
        try testing.expectEqual(c.height, t.heightAt(w[0] + 0.9 * c.radius, w[1]).?);
        try testing.expectEqual(Hex.zero, t.chunkAt(w[0], w[1]));
    }
}

test "a gap is interpolated between the two cells' heights" {
    var t = try testTerrain();
    defer t.deinit();
    const chunk = t.chunks.get(.zero).?.chunk;
    var checked: usize = 0;
    for (chunk.cells) |a| {
        const nb = a.hex().add(Hex.directions[1]);
        const j = t.chunks.get(.zero).?.cells.get(nb) orelse continue;
        const b = chunk.cells[j];
        const wa = a.hex().toWorld(t.hex_size);
        const wb = nb.toWorld(t.hex_size);
        // The midpoint of the centres lies in the gap between the two faces.
        const y = t.heightAt((wa[0] + wb[0]) / 2, (wa[1] + wb[1]) / 2).?;
        try testing.expect(y >= @min(a.height, b.height) - 1e-4);
        try testing.expect(y <= @max(a.height, b.height) + 1e-4);
        checked += 1;
    }
    try testing.expect(checked > 10);
}

test "no cracks: every point over the chunk's inner cells has ground" {
    var t = try testTerrain();
    defer t.deinit();
    const loaded = t.chunks.get(.zero).?;
    var samples: usize = 0;
    for (loaded.chunk.cells) |c| {
        // Only cells whose neighbours are all in this chunk: the rest border
        // ground that isn't loaded here.
        const inner = for (c.hex().neighbors()) |n| {
            if (!loaded.cells.contains(n)) break false;
        } else true;
        if (!inner) continue;
        const w = c.hex().toWorld(t.hex_size);
        // A 9×9 grid over the cell's full-size apothem square.
        const half = t.hex_size * 0.86;
        for (0..9) |i| for (0..9) |k| {
            const fx = (@as(f32, @floatFromInt(i)) / 8 - 0.5) * 2 * half;
            const fz = (@as(f32, @floatFromInt(k)) / 8 - 0.5) * 2 * half;
            try testing.expect(t.heightAt(w[0] + fx, w[1] + fz) != null);
            samples += 1;
        };
    }
    try testing.expect(samples > 1000);
}

test "nothing outside the loaded chunks; remove unloads" {
    var t = try testTerrain();
    defer t.deinit();
    try testing.expectEqual(null, t.heightAt(1e4, 0));
    try testing.expect(t.asGround().heightAt(0, 0) != null);
    t.remove(.zero);
    try testing.expect(!t.chunks.contains(.zero));
    try testing.expectEqual(null, t.heightAt(0, 0));
    t.remove(.zero); // removing twice is fine
}

test "cellHeight: a loaded cell's face height; null off the terrain" {
    var t = try testTerrain();
    defer t.deinit();
    const chunk = t.chunks.get(.zero).?.chunk;
    const cell = chunk.cells[5];
    try std.testing.expectEqual(cell.height, t.cellHeight(cell.hex()).?);
    try std.testing.expectEqual(cell.height, chunk.cellTris(5)[0].a.y);
    try std.testing.expectEqual(null, t.cellHeight(.{ .q = 500, .r = 0 }));
}

test "faceAt: a face's own cell; null over a gap or off the terrain" {
    var t = try testTerrain();
    defer t.deinit();
    const loaded = t.chunks.get(.zero).?;
    var gaps: usize = 0;
    for (loaded.chunk.cells) |a| {
        const w = a.hex().toWorld(t.hex_size);
        try testing.expectEqual(a.hex(), t.faceAt(w[0], w[1]).?);
        try testing.expectEqual(a.hex(), t.faceAt(w[0] + 0.9 * a.radius, w[1]).?);
        // Midway between two cells' centres is a gap (faces are shrunk).
        const nb = a.hex().add(Hex.directions[1]);
        if (!loaded.cells.contains(nb)) continue;
        const wb = nb.toWorld(t.hex_size);
        try testing.expectEqual(null, t.faceAt((w[0] + wb[0]) / 2, (w[1] + wb[1]) / 2));
        gaps += 1;
    }
    try testing.expect(gaps > 10);
    try testing.expectEqual(null, t.faceAt(1e4, 0));
}

const down = Vec3.up.scale(-1);

/// Point `dy` m above cell `c`'s centre.
fn above(t: Terrain, c: Chunk.Cell, dy: f32) Vec3 {
    const w = c.hex().toWorld(t.hex_size);
    return .{ .x = w[0], .y = c.height + dy, .z = w[1] };
}

test "raycast: straight down lands on the face, within reach only" {
    var t = try testTerrain();
    defer t.deinit();
    for (t.chunks.get(.zero).?.chunk.cells) |c| {
        const eye = above(t, c, 1.7);
        const hit = t.raycast(eye, down, 5).?;
        try testing.expectApproxEqAbs(c.height, hit.y, 1e-3);
        try testing.expectEqual(c.hex(), t.faceAt(hit.x, hit.z).?);
        try testing.expectEqual(null, t.raycast(eye, down, 1.5)); // short of the ground
        try testing.expectEqual(null, t.raycast(eye, Vec3.up, 50)); // looking up
    }
}

test "raycast: a slanted ray stops on the ground surface" {
    var t = try testTerrain();
    defer t.deinit();
    const dir = (Vec3{ .x = 1, .y = -0.6, .z = 0.3 }).normalize();
    var hits: usize = 0;
    for (t.chunks.get(.zero).?.chunk.cells) |c| {
        // 20 m reaches about 3 cells on: stay that far inside the one loaded
        // chunk, or the ray stops against the side of its unloaded rim.
        if (c.hex().distance(.zero) + 3 > world.chunk_radius) continue;
        const hit = t.raycast(above(t, c, 1.7), dir, 20) orelse continue;
        try testing.expectApproxEqAbs(t.heightAt(hit.x, hit.z).?, hit.y, 1e-3);
        hits += 1;
    }
    try testing.expect(hits > 10);
}

test "raycast: an origin under the ground hits at once; unloaded ground isn't hit" {
    var t = try testTerrain();
    defer t.deinit();
    const under = above(t, t.chunks.get(.zero).?.chunk.cells[0], -1);
    try testing.expectEqual(under, t.raycast(under, Vec3.up, 5).?);
    const far: Vec3 = .{ .x = 1e4, .y = 1, .z = 0 };
    try testing.expectEqual(null, t.raycast(far, down, 100));
}

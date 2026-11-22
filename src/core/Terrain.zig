//! The loaded part of the world: parsed chunks by coordinate, and the ground
//! height under any point on them. Holds views only; whoever loaded the
//! chunk bytes keeps them alive until `remove`.
const std = @import("std");
const Hex = @import("Hex.zig");
const Chunk = @import("Chunk.zig");
const ground = @import("ground.zig");
const Terrain = @This();

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

pub fn contains(t: Terrain, coord: Hex) bool {
    return t.chunks.contains(coord);
}

/// The chunk coordinate that world point `x`, `z` falls in.
pub fn chunkAt(t: Terrain, x: f32, z: f32) Hex {
    return Hex.fromWorld(x, z, t.hex_size).toLowerRes(t.chunk_radius);
}

/// Ground height at world `x`, `z`, or null off the loaded terrain.
pub fn heightAt(t: Terrain, x: f32, z: f32) ?f32 {
    // The point lies in its hex's full hexagon. That area is covered by the
    // hex's face, half of each gap quad round it and the junction tris at
    // its corners, which the hex or one of its neighbours owns.
    const h = Hex.fromWorld(x, z, t.hex_size);
    const nb = h.neighbors();
    for ([_]Hex{h} ++ nb) |owner| {
        const loaded = t.chunks.getPtr(owner.toLowerRes(t.chunk_radius)) orelse continue;
        const i = loaded.cells.get(owner) orelse continue;
        for (loaded.chunk.cellTris(loaded.chunk.cells[i])) |tri| {
            if (ground.heightInTri(tri, x, z)) |y| return y;
        }
    }
    return null;
}

/// This terrain as the ground rule's height lookup. `t` must stay put.
pub fn asGround(t: *const Terrain) ground.Ground {
    return .{ .ctx = t, .heightAtFn = heightAtErased };
}

fn heightAtErased(ctx: *const anyopaque, x: f32, z: f32) ?f32 {
    const t: *const Terrain = @ptrCast(@alignCast(ctx));
    return t.heightAt(x, z);
}

const testing = std.testing;
const test_data = @import("test_data.zig");

fn testTerrain() !Terrain {
    var t: Terrain = .init(testing.allocator, test_data.chunk_radius, test_data.hex_size);
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
    try testing.expect(!t.contains(.zero));
    try testing.expectEqual(null, t.heightAt(0, 0));
    t.remove(.zero); // removing twice is fine
}

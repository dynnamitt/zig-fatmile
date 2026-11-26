//! Which chunks to load and free as the player moves: pure maths, so the
//! loader in the exe only does the file and GPU work it is told to.
//!
//! Chunks within `load` chunk-steps of the player's chunk are wanted. Loaded
//! chunks are freed once they are more than `keep` steps away; `keep` above
//! `load` stops a chunk from being freed and reloaded while the player walks
//! back and forth over a border. At most `budget` chunks load per frame,
//! nearest first, so a border crossing spreads its work over frames.
const std = @import("std");
const Hex = @import("Hex.zig");

pub const Range = struct {
    load: u32,
    keep: u32,
};

/// The game's range: 19 chunks round the player's own, freed past 3 steps.
pub const chunk_range: Range = .{ .load = 2, .keep = 3 };
/// Metres loaded in every direction from anywhere in the player's chunk,
/// once `chunk_range` has loaded (1 step would give 45 m). A fine sweep
/// put the worst case, from a jagged chunk corner, at 118.5 m; this keeps a
/// margin for what the test's sampling can miss. `sky.fog_end` must stay
/// within it.
pub const min_loaded_radius: f32 = 112;

/// Chunks a step into a neighbouring chunk brings into `range.load`: the
/// far side of the new range. Loading this many per frame keeps the whole
/// range loaded through every border crossing, so `min_loaded_radius` holds
/// while walking, not just once loading settles.
pub fn crossingLoads(range: Range) usize {
    return 2 * @as(usize, range.load) + 1;
}

pub const Plan = struct {
    /// Load these, in order (nearest first).
    load: []const Hex,
    /// Free these.
    unload: []const Hex,
};

/// Plans one frame. `world.has(coord)` says whether the world has a chunk
/// there; `loaded` lists the chunks loaded now. `load_buf` needs
/// `Hex.rangeCount(range.load)` slots and `unload_buf` `loaded.len`.
pub fn plan(range: Range, center: Hex, world: anytype, loaded: []const Hex, budget: usize, load_buf: []Hex, unload_buf: []Hex) Plan {
    std.debug.assert(range.keep >= range.load);
    var n_unload: usize = 0;
    for (loaded) |c| {
        if (Hex.distance(c, center) > range.keep) {
            unload_buf[n_unload] = c;
            n_unload += 1;
        }
    }
    var n_load: usize = 0;
    for (Hex.spiral(center, range.load, load_buf)) |c| {
        if (n_load == budget) break;
        if (!world.has(c) or Hex.indexOf(loaded, c) != null) continue;
        load_buf[n_load] = c; // n_load ≤ the spiral index, so this never overwrites unread entries
        n_load += 1;
    }
    return .{ .load = load_buf[0..n_load], .unload = unload_buf[0..n_unload] };
}

const testing = std.testing;

/// Test world: every chunk within `radius` of the origin.
const Disc = struct {
    radius: u32,
    pub fn has(d: Disc, c: Hex) bool {
        return Hex.distance(c, .zero) <= d.radius;
    }
};

test "loads every wanted chunk nearest first, within budget" {
    const r: Range = .{ .load = 1, .keep = 2 };
    var lb: [7]Hex = undefined;
    var ub: [0]Hex = undefined;
    const p = plan(r, .zero, Disc{ .radius = 10 }, &.{}, 3, &lb, &ub);
    try testing.expectEqual(3, p.load.len);
    try testing.expectEqual(Hex.zero, p.load[0]); // the player's own chunk first
    const all = plan(r, .zero, Disc{ .radius = 10 }, &.{}, 100, &lb, &ub);
    try testing.expectEqual(7, all.load.len);
}

test "skips chunks the world doesn't have or that are loaded" {
    const r: Range = .{ .load = 1, .keep = 1 };
    var lb: [7]Hex = undefined;
    var ub: [1]Hex = undefined;
    const loaded = [_]Hex{.zero};
    const p = plan(r, .{ .q = 1, .r = 0 }, Disc{ .radius = 1 }, &loaded, 100, &lb, &ub);
    // Around (1, 0) the disc of radius 1 has (1, 0), (1, -1), (0, 1) and the
    // loaded origin.
    try testing.expectEqual(3, p.load.len);
    for (p.load) |c| try testing.expect(!c.eql(.zero));
    try testing.expectEqual(0, p.unload.len);
}

test "frees only past keep, so a border can be crossed back and forth" {
    const r: Range = .{ .load = 1, .keep = 2 };
    var lb: [7]Hex = undefined;
    var ub: [3]Hex = undefined;
    const loaded = [_]Hex{ .zero, .{ .q = 2, .r = 0 }, .{ .q = -3, .r = 0 } };
    const p = plan(r, .{ .q = 1, .r = 0 }, Disc{ .radius = 0 }, &loaded, 100, &lb, &ub);
    try testing.expectEqual(1, p.unload.len);
    try testing.expectEqual(Hex{ .q = -3, .r = 0 }, p.unload[0]);
}

test "a walk across the world: player's chunk always loaded, budget kept" {
    // One plan per frame while walking straight through 8 chunks, 30 frames
    // per chunk (a chunk is ~80 m; that's sprinting at 160 m/s at 60 FPS).
    const r: Range = .{ .load = 1, .keep = 2 };
    const world: Disc = .{ .radius = 20 };
    const budget = 2;
    var loaded: std.ArrayList(Hex) = .empty;
    defer loaded.deinit(testing.allocator);
    var lb: [7]Hex = undefined;
    var ub: [64]Hex = undefined;
    // Start: load everything in range at once.
    for (plan(r, .zero, world, loaded.items, 100, &lb, &ub).load) |c| try loaded.append(testing.allocator, c);
    var frees: usize = 0;
    for (0..8 * 30) |f| {
        const center: Hex = .{ .q = @intCast(f / 30), .r = 0 };
        try testing.expect(Hex.indexOf(loaded.items, center) != null);
        const p = plan(r, center, world, loaded.items, budget, &lb, &ub);
        try testing.expect(p.load.len <= budget);
        for (p.unload) |c| {
            _ = loaded.swapRemove(Hex.indexOf(loaded.items, c).?);
            frees += 1;
        }
        for (p.load) |c| try loaded.append(testing.allocator, c);
        try testing.expect(loaded.items.len <= Hex.rangeCount(r.keep));
    }
    try testing.expect(frees > 0);
}

test "min_loaded_radius is loaded all round, from anywhere in the chunk" {
    const world = @import("world.zig");
    // Sample chunk 0,0 (within its bounding box) and look out every 2°.
    const corner = Hex.toWorld(.{ .q = @intCast(world.chunk_radius + 2), .r = 0 }, world.hex_size);
    const reach = @abs(corner[0]) + @abs(corner[1]);
    const step = world.hex_size / 2;
    const dirs = 180;
    var x: f32 = -reach;
    while (x <= reach) : (x += step) {
        var z: f32 = -reach;
        while (z <= reach) : (z += step) {
            const here = Hex.fromWorld(x, z, world.hex_size).toLowerRes(world.chunk_radius);
            if (!here.eql(Hex.zero)) continue;
            for (0..dirs) |i| {
                const a = std.math.tau * @as(f32, @floatFromInt(i)) / dirs;
                const there = Hex.fromWorld(x + min_loaded_radius * @cos(a), z + min_loaded_radius * @sin(a), world.hex_size).toLowerRes(world.chunk_radius);
                try std.testing.expect(Hex.distance(here, there) <= chunk_range.load);
            }
        }
    }
}

test "crossingLoads: what one step into a neighbour leaves to load" {
    for ([_]Range{ .{ .load = 1, .keep = 2 }, chunk_range }) |r| {
        var buf: [Hex.rangeCount(4)]Hex = undefined;
        const before = Hex.spiral(.zero, r.load, &buf);
        var load_buf: [Hex.rangeCount(4)]Hex = undefined;
        var unload_buf: [Hex.rangeCount(4)]Hex = undefined;
        const p = plan(r, Hex.directions[0], Disc{ .radius = 100 }, before, std.math.maxInt(usize), &load_buf, unload_buf[0..before.len]);
        try testing.expectEqual(crossingLoads(r), p.load.len);
    }
}

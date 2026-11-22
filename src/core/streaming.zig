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

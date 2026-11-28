//! The world's stored terrain edits: the cells the shovel has lowered. apicult
//! builds every chunk from noise plus these (apicult-desigual-rs's D2: the
//! consumer keeps the edits, keyed by owning chunk, and passes a chunk's own
//! and ring edits on every build). An edit is the cell's final height, not an
//! offset (D13).
//!
//! A chunk's layout also holds its entangled ring: the neighbour chunks' cells
//! at distance `chunk_radius + 1` from its centre. So an edit of a cell on a
//! chunk's edge or corner is in 2 or 3 layouts (`chunksHolding`), and each
//! of them gets it (`forChunk`).
const std = @import("std");
const Hex = @import("Hex.zig");
const Edits = @This();

/// One edit as apicult-ffi's `ac_chunk` takes it (its `AcEdit`).
pub const Edit = extern struct {
    q: i32,
    r: i32,
    /// `height` or `size`.
    channel: u32,
    /// The channel's final value, in metres.
    value: f32,

    pub fn hex(e: Edit) Hex {
        return .{ .q = e.q, .r = e.r };
    }
};
/// `Edit.channel` values, as apicult-ffi's `AC_HEIGHT` / `AC_SIZE`.
pub const height: u32 = 0;
pub const size: u32 = 1;

/// How much one dig lowers a cell, in metres.
pub const dig_depth: f32 = 1;
/// The lowest a dig takes a cell: the bottom of the height noise.
pub const min_height: f32 = 0;

allocator: std.mem.Allocator,
chunk_radius: u32,
/// Owning chunk → the edits of its cells.
by_chunk: std.AutoHashMapUnmanaged(Hex, std.ArrayListUnmanaged(Edit)) = .empty,

pub fn init(allocator: std.mem.Allocator, chunk_radius: u32) Edits {
    return .{ .allocator = allocator, .chunk_radius = chunk_radius };
}

pub fn deinit(e: *Edits) void {
    var it = e.by_chunk.valueIterator();
    while (it.next()) |list| list.deinit(e.allocator);
    e.by_chunk.deinit(e.allocator);
}

/// Sets `cell`'s `channel` to `value`, replacing an earlier edit of the same.
pub fn set(e: *Edits, cell: Hex, channel: u32, value: f32) error{OutOfMemory}!void {
    const gop = try e.by_chunk.getOrPut(e.allocator, cell.toLowerRes(e.chunk_radius));
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    for (gop.value_ptr.items) |*old| {
        if (old.hex().eql(cell) and old.channel == channel) {
            old.value = value;
            return;
        }
    }
    try gop.value_ptr.append(e.allocator, .{ .q = cell.q, .r = cell.r, .channel = channel, .value = value });
}

/// The stored value of `cell`'s `channel`, or null if it was never edited.
pub fn get(e: *const Edits, cell: Hex, channel: u32) ?f32 {
    const list = e.by_chunk.get(cell.toLowerRes(e.chunk_radius)) orelse return null;
    for (list.items) |x| if (x.hex().eql(cell) and x.channel == channel) return x.value;
    return null;
}

/// Appends the edits chunk `coord`'s layout needs: its own cells' and its
/// entangled ring's (the 6 neighbour chunks' edits within `chunk_radius + 1`
/// of its centre).
pub fn forChunk(e: *const Edits, coord: Hex, out: *std.ArrayListUnmanaged(Edit), gpa: std.mem.Allocator) error{OutOfMemory}!void {
    const center = coord.toHigherRes(e.chunk_radius);
    for ([1]Hex{coord} ++ coord.neighbors()) |owner| {
        const list = e.by_chunk.get(owner) orelse continue;
        for (list.items) |x| {
            if (x.hex().distance(center) <= e.chunk_radius + 1) try out.append(gpa, x);
        }
    }
}

/// The chunks whose layouts hold `cell`, which a change to it rebuilds
/// (apicult's consumer rule 3): its own chunk, then any whose entangled ring
/// it is in. 1 for an interior cell, 2 on a chunk's edge, 3 at a corner.
pub fn chunksHolding(cell: Hex, chunk_radius: u32, buf: *[3]Hex) []Hex {
    const own = cell.toLowerRes(chunk_radius);
    buf[0] = own;
    var n: usize = 1;
    for (own.neighbors()) |c| {
        if (cell.distance(c.toHigherRes(chunk_radius)) == chunk_radius + 1) {
            buf[n] = c;
            n += 1;
        }
    }
    return buf[0..n];
}

/// A dug cell's new height: `dig_depth` lower, but not below `min_height`.
pub fn dug(current: f32) f32 {
    return @max(min_height, current - dig_depth);
}

const testing = std.testing;

test "chunksHolding: 1 inside a chunk, 2 on its edges, 3 at its 6 corners" {
    const r = 6;
    const coord: Hex = .{ .q = 2, .r = -1 };
    const center = coord.toHigherRes(r);
    var buf: [Hex.rangeCount(r)]Hex = undefined;
    var counts: [4]usize = @splat(0);
    for (Hex.spiral(center, r, &buf)) |cell| {
        var hold: [3]Hex = undefined;
        const chunks = chunksHolding(cell, r, &hold);
        try testing.expectEqual(coord, chunks[0]);
        for (chunks[1..]) |c| {
            try testing.expectEqual(1, c.distance(coord));
            try testing.expectEqual(r + 1, cell.distance(c.toHigherRes(r)));
        }
        if (cell.distance(center) < r) try testing.expectEqual(1, chunks.len);
        counts[chunks.len] += 1;
    }
    try testing.expectEqual(6, counts[3]);
    try testing.expectEqual(6 * r - 6, counts[2]);
    try testing.expectEqual(Hex.rangeCount(r - 1), counts[1]);
}

test "set replaces, get reads back, per channel" {
    var e: Edits = .init(testing.allocator, 6);
    defer e.deinit();
    const cell: Hex = .{ .q = 3, .r = -2 };
    try testing.expectEqual(null, e.get(cell, height));
    try e.set(cell, height, 5);
    try e.set(cell, height, 4);
    try e.set(cell, size, 1.5);
    try testing.expectEqual(4, e.get(cell, height));
    try testing.expectEqual(1.5, e.get(cell, size));
    try testing.expectEqual(2, e.by_chunk.get(cell.toLowerRes(6)).?.items.len);
}

test "forChunk: own edits and the ring's, not the neighbours' farther cells" {
    const r = 6;
    var e: Edits = .init(testing.allocator, r);
    defer e.deinit();
    const coord: Hex = .zero;
    const center = coord.toHigherRes(r);
    const east = (Hex{ .q = 1, .r = 0 }).toHigherRes(r);
    const own: Hex = center.add(.{ .q = 1, .r = 0 });
    // A cell of the east chunk, one step past this chunk's edge: in its ring.
    var ring: Hex = undefined;
    var far: Hex = undefined;
    var buf: [Hex.rangeCount(r)]Hex = undefined;
    for (Hex.spiral(east, r, &buf)) |h| {
        if (h.distance(center) == r + 1) ring = h;
        if (h.distance(center) > r + 2) far = h;
    }
    try e.set(own, height, 1);
    try e.set(ring, height, 2);
    try e.set(far, height, 3);
    var out: std.ArrayListUnmanaged(Edit) = .empty;
    defer out.deinit(testing.allocator);
    try e.forChunk(coord, &out, testing.allocator);
    try testing.expectEqual(2, out.items.len);
    for (out.items) |x| try testing.expect(x.hex().eql(own) or x.hex().eql(ring));
    // Every chunk holding the ring cell gets its edit.
    var hold: [3]Hex = undefined;
    for (chunksHolding(ring, r, &hold)) |c| {
        out.clearRetainingCapacity();
        try e.forChunk(c, &out, testing.allocator);
        var found = false;
        for (out.items) |x| found = found or x.hex().eql(ring);
        try testing.expect(found);
    }
}

test "dug lowers by dig_depth, down to min_height" {
    try testing.expectEqual(4, dug(5));
    try testing.expectEqual(min_height, dug(0.25));
    try testing.expectEqual(min_height, dug(min_height));
}

//! Axial hex coordinate, ported from the `hexx` 0.24 crate that generates the
//! terrain (apicult-desigual-rs): same flat-top layout, rounding and
//! `to_lower_res` chunking, so cells and chunks found here are the ones the
//! chunk files were written with. World x/z are hexx's 2D x/y.
const std = @import("std");
const Hex = @This();

q: i32,
r: i32,

pub const zero: Hex = .{ .q = 0, .r = 0 };

// hexx's f32 constants (orientation.rs), so results match it bit for bit.
const sqrt_3: f32 = 1.732_050_8;
const half_sqrt_3: f32 = sqrt_3 / 2.0;

/// hexx `EdgeDirection::ALL_DIRECTIONS`, as axial offsets.
pub const directions = [6]Hex{
    .{ .q = 1, .r = -1 }, .{ .q = 1, .r = 0 },  .{ .q = 0, .r = 1 },
    .{ .q = -1, .r = 1 }, .{ .q = -1, .r = 0 }, .{ .q = 0, .r = -1 },
};

pub fn s(h: Hex) i32 {
    return -h.q - h.r;
}

pub fn eql(a: Hex, b: Hex) bool {
    return a.q == b.q and a.r == b.r;
}

/// Orders by q, then r: the order the generator writes chunks in.
pub fn order(a: Hex, b: Hex) std.math.Order {
    return std.math.order(a.q, b.q).differ() orelse std.math.order(a.r, b.r);
}

/// Index of `h` in `list`, or null.
pub fn indexOf(list: []const Hex, h: Hex) ?usize {
    for (list, 0..) |x, i| if (x.eql(h)) return i;
    return null;
}

pub fn add(a: Hex, b: Hex) Hex {
    return .{ .q = a.q + b.q, .r = a.r + b.r };
}

pub fn scale(h: Hex, k: i32) Hex {
    return .{ .q = h.q * k, .r = h.r * k };
}

/// Steps between `a` and `b` (hexx `unsigned_distance_to`).
pub fn distance(a: Hex, b: Hex) u32 {
    const d: Hex = .{ .q = a.q - b.q, .r = a.r - b.r };
    return @max(@abs(d.q), @abs(d.r), @abs(d.s()));
}

pub fn neighbors(h: Hex) [6]Hex {
    var out: [6]Hex = undefined;
    for (directions, &out) |d, *n| n.* = h.add(d);
    return out;
}

/// World x/z of this hex's centre, for hexes of `size` (centre to corner):
/// hexx `HexLayout::hex_to_world_pos` with flat orientation, scale `size`.
pub fn toWorld(h: Hex, size: f32) [2]f32 {
    const q: f32 = @floatFromInt(h.q);
    const r: f32 = @floatFromInt(h.r);
    return .{ (1.5 * q + 0.0 * r) * size, (half_sqrt_3 * q + sqrt_3 * r) * size };
}

/// The hex whose (full, `size`) hexagon holds world point `x`, `z`: hexx
/// `world_pos_to_hex`.
pub fn fromWorld(x: f32, z: f32, size: f32) Hex {
    const px = x / size;
    const pz = z / size;
    return round((2.0 / 3.0) * px + 0.0 * pz, (-1.0 / 3.0) * px + (sqrt_3 / 3.0) * pz);
}

/// Nearest hex to fractional axial `q`, `r` (hexx `Hex::round`).
pub fn round(q: f32, r: f32) Hex {
    var qr = @round(q);
    var rr = @round(r);
    const dq = q - qr;
    const dr = r - rr;
    if (@abs(dq) >= @abs(dr)) {
        qr += @round(@mulAdd(f32, 0.5, dr, dq));
    } else {
        rr += @round(@mulAdd(f32, 0.5, dq, dr));
    }
    return .{ .q = @intFromFloat(qr), .r = @intFromFloat(rr) };
}

/// Hexes within `radius` steps: `3·radius·(radius + 1) + 1`.
pub fn rangeCount(radius: u32) u32 {
    return 3 * radius * (radius + 1) + 1;
}

/// The hex of a grid whose cells are hexagons of `radius` that holds `h`
/// (hexx `to_lower_res`): how the terrain is split into chunks.
pub fn toLowerRes(h: Hex, radius: u32) Hex {
    const x = h.q;
    const y = h.r;
    const z = h.s();
    const area: f32 = @floatFromInt(rangeCount(radius));
    const shift: i32 = @intCast(3 * radius + 2);
    const lx = floorDiv(y + shift * x, area);
    const ly = floorDiv(z + shift * y, area);
    const lz = floorDiv(x + shift * z, area);
    return .{ .q = floorDiv(1 + lx - ly, 3.0), .r = floorDiv(1 + ly - lz, 3.0) };
}

fn floorDiv(n: i32, d: f32) i32 {
    const nf: f32 = @floatFromInt(n);
    return @intFromFloat(@floor(nf / d));
}

/// Fills `out` with every hex within `radius` of `center`, nearest first
/// (ring 0, then ring 1, …), and returns the filled part. `out` needs
/// `rangeCount(radius)` slots.
pub fn spiral(center: Hex, radius: u32, out: []Hex) []Hex {
    std.debug.assert(out.len >= rangeCount(radius));
    out[0] = center;
    var n: usize = 1;
    var k: i32 = 1;
    while (k <= radius) : (k += 1) {
        // Start k steps along direction 4, then walk k steps along each side.
        var h = center.add(directions[4].scale(k));
        for (0..6) |side| {
            for (0..@intCast(k)) |_| {
                out[n] = h;
                n += 1;
                h = h.add(directions[side]);
            }
        }
    }
    return out[0..n];
}

const testing = std.testing;
const Chunk = @import("Chunk.zig");
const test_chunk = @import("test_data.zig");

test "distance and neighbors" {
    try testing.expectEqual(0, distance(zero, zero));
    try testing.expectEqual(3, distance(.{ .q = 3, .r = -1 }, zero));
    try testing.expectEqual(4, distance(.{ .q = -2, .r = -2 }, zero));
    for (zero.neighbors()) |n| try testing.expectEqual(1, distance(n, zero));
}

test "round picks the nearest hex, like hexx" {
    try testing.expectEqual(zero, round(0.3, 0.2));
    try testing.expectEqual(Hex{ .q = 1, .r = 0 }, round(0.4, 0.4)); // s = -0.8 is the far one
    try testing.expectEqual(Hex{ .q = 1, .r = 0 }, round(0.9, 0.05));
    try testing.expectEqual(Hex{ .q = -1, .r = 1 }, round(-0.6, 0.55));
    for (zero.neighbors()) |n| {
        const w = n.toWorld(4);
        try testing.expectEqual(n, fromWorld(w[0], w[1], 4));
    }
}

test "world points inside a hex map back to it" {
    const size: f32 = 4;
    const c: Hex = .{ .q = 5, .r = -3 };
    const w = c.toWorld(size);
    // 0.99 of the way to each corner (corners are at angle 60°·i, flat-top).
    for (0..6) |i| {
        const a = std.math.pi / 3.0 * @as(f32, @floatFromInt(i));
        try testing.expectEqual(c, fromWorld(w[0] + 0.99 * size * @cos(a), w[1] + 0.99 * size * @sin(a), size));
    }
}

test "toLowerRes: the chunk round the origin holds exactly its radius' hexes" {
    var buf: [rangeCount(3)]Hex = undefined;
    for (spiral(zero, 3, &buf), 0..) |h, i| {
        const inside = i < rangeCount(2);
        try testing.expectEqual(inside, zero.eql(h.toLowerRes(2)));
    }
}

test "spiral is nearest first, unique and complete" {
    var buf: [rangeCount(3)]Hex = undefined;
    const c: Hex = .{ .q = -2, .r = 7 };
    const all = spiral(c, 3, &buf);
    try testing.expectEqual(37, all.len);
    for (all, 0..) |h, i| {
        try testing.expect(distance(h, c) <= 3);
        if (i > 0) try testing.expect(distance(h, c) >= distance(all[i - 1], c));
        try testing.expectEqual(null, indexOf(all[0..i], h));
    }
}

test "matches the generator on a real chunk: centres, chunk of each cell" {
    const chunk = try Chunk.parse(test_chunk.chunk_bytes);
    for (chunk.cells) |cell| {
        const h = cell.hex();
        try testing.expectEqual(chunk.coord, h.toLowerRes(test_chunk.chunk_radius));
        // The first face tri's first corner is the cell centre.
        const centre = chunk.tris[cell.first_tri].a;
        const w = h.toWorld(test_chunk.hex_size);
        try testing.expectApproxEqAbs(w[0], centre.x, 1e-4);
        try testing.expectApproxEqAbs(w[1], centre.z, 1e-4);
        try testing.expectEqual(h, fromWorld(centre.x, centre.z, test_chunk.hex_size));
    }
}

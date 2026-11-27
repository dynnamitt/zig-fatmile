//! One terrain chunk's bytes, read in place: the slices point into them,
//! nothing is copied. apicult-ffi's `ac_chunk` writes the format
//! (`apicult-ffi/src/lib.rs`), each part a straight copy of one of apicult's
//! chunk functions; keep the two in sync.
//!
//! | part | layout (little-endian) |
//! |---|---|
//! | header (40 B) | `"HXCK"`, `u32 version`, `i32 q`, `i32 r`, `u32 n_cells`, `u32 n_tris`, `u32 n_ring`, `u32 n_seam_tris`, `u64 hash` |
//! | cells | `n_cells × Cell` (16 B) |
//! | tris | `n_tris × Tri`, `tri_sequence` (14) per cell: 6 face tris (centre, rim corner, rim corner), 6 gap-quad tris (pairs), 2 junction tris |
//! | ring | `n_ring × RingCell` (4 B): each entangled ring cell's seam tri counts |
//! | seam keys | `n_seam_tris × SeamKey` (16 B) |
//! | seam tris | `n_seam_tris × Tri`: per ring cell its gap-quad tris (pairs), then its junction tris |
//!
//! The seam tris are triangles neighbour chunks own that touch this one, so
//! this chunk can fill the gap while a neighbour isn't loaded; draw one only
//! while its key's `drawn` holds (apicult's consumer rule 1). A chunk has a
//! few distinct keys (6 neighbour owners, plus corners); `parse` lists them
//! in `groups`, and a `SeamMask` picks among them.
//!
//! `hash` is FNV-1a 64 over every byte after the header.
const std = @import("std");
const builtin = @import("builtin");
const Hex = @import("Hex.zig");
const Vec3 = @import("vec.zig").Vec3;
const Chunk = @This();

pub const magic = "HXCK";
/// v4: apicult's chunk functions copied as they come (v3 grouped seams in the FFI).
pub const version: u32 = 4;
pub const header_len = 40;
/// The tris every own cell owns, back to back: its `tri_sequence`.
pub const tri_sequence = 14;
/// Each cell's face fan, first in its sequence.
pub const face_tris = 6;
/// Its 3 gap quads' tris, after the face.
pub const quad_tris = 6;

/// One own cell's state. Its triangles are `cellTris(i)` for its index `i`.
pub const Cell = extern struct {
    q: i32,
    r: i32,
    height: f32,
    radius: f32,

    pub fn hex(c: Cell) Hex {
        return .{ .q = c.q, .r = c.r };
    }
};

pub const Tri = extern struct { a: Vec3, b: Vec3, c: Vec3 };

/// One entangled ring cell's seam tris: its gap-quad tris, then its junctions.
pub const RingCell = extern struct {
    n_quad_tris: u16,
    n_junction_tris: u16,

    pub fn triCount(c: RingCell) u32 {
        return @as(u32, c.n_quad_tris) + c.n_junction_tris;
    }
};

/// Which chunk owns a seam tri, and which third chunk a corner one touches
/// (apicult's `EntangledSeam`). With no third chunk, `also` repeats the owner.
pub const SeamKey = extern struct {
    owner_q: i32,
    owner_r: i32,
    also_q: i32,
    also_r: i32,

    /// The chunk that owns the tri.
    /// @returns {Hex} its coordinate on the chunk lattice; a neighbour of the carrier.
    pub fn owner(k: SeamKey) Hex {
        return .{ .q = k.owner_q, .r = k.owner_r };
    }

    /// The third chunk a corner junction touches.
    /// @returns {?Hex} its coordinate, or null for a tri between two chunks.
    pub fn also(k: SeamKey) ?Hex {
        const a: Hex = .{ .q = k.also_q, .r = k.also_r };
        return if (a.eql(k.owner())) null else a;
    }

    pub fn eql(a: SeamKey, b: SeamKey) bool {
        return std.meta.eql(a, b);
    }

    /// apicult's consumer rule 1 (`EntangledSeam::drawn`): whether chunk
    /// `carrier` (whose seam tris hold one with this key) should draw it now.
    /// True while no loaded chunk draws it: the owner isn't loaded, and for a
    /// corner the `also` chunk isn't either, or sorts after the carrier in
    /// `(q, r)` order (so exactly one of two loaded carriers draws it).
    /// `testdata/entangled_seam_drawn.tsv` (apicult's table) holds the cases.
    /// @param carrier {Hex} the chunk whose seam tris hold the tri.
    /// @param loaded {anytype} has `fn loaded(Hex) bool`.
    /// @returns {bool} whether to draw it.
    pub fn drawn(k: SeamKey, carrier: Hex, loaded: anytype) bool {
        if (loaded.loaded(k.owner())) return false;
        const a = k.also() orelse return true;
        return !loaded.loaded(a) or carrier.q < a.q or (carrier.q == a.q and carrier.r < a.r);
    }
};

/// Which chunks are loaded, for `SeamKey.drawn`: a plain list, searched in
/// order (a few dozen chunks at most).
pub const LoadedSet = struct {
    coords: []const Hex,

    pub fn loaded(l: LoadedSet, c: Hex) bool {
        return Hex.indexOf(l.coords, c) != null;
    }
};

/// Most distinct seam keys a chunk may have, so a set of them fits in a
/// `SeamMask`. apicult makes at most 12: 6 neighbour owners and 6 corners.
pub const max_seams = 16;
/// Bit `i` stands for `groups()[i]`.
pub const SeamMask = u16;

comptime {
    // The file is little-endian and read in place.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Cell) == 16 and @sizeOf(Tri) == 36 and @sizeOf(RingCell) == 4 and @sizeOf(SeamKey) == 16);
    std.debug.assert(max_seams <= @bitSizeOf(SeamMask));
}

coord: Hex,
cells: []align(1) const Cell,
tris: []align(1) const Tri,
ring: []align(1) const RingCell,
seam_keys: []align(1) const SeamKey,
seam_tris: []align(1) const Tri,
/// The distinct seam keys, in first-seen order; see `groups`.
group_buf: [max_seams]SeamKey = undefined,
n_groups: u8 = 0,

pub const Error = error{ TooShort, BadMagic, UnsupportedVersion, PayloadLength, HashMismatch, BadCellRun, BadSeamRun, TooManySeams };

/// Reads a chunk in place and checks it: magic, version, lengths, hash,
/// `tri_sequence` tris per cell, ring counts that tile the seam tris with
/// whole quads under one key per ring cell, and at most `max_seams` distinct
/// seam keys.
/// @param bytes {[]const u8} what `ac_chunk` returned; must outlive the chunk.
/// @returns {Error!Chunk} views into `bytes`.
pub fn parse(bytes: []const u8) Error!Chunk {
    if (bytes.len < header_len) return error.TooShort;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
    if (readInt(u32, bytes, 4) != version) return error.UnsupportedVersion;
    const n_cells = readInt(u32, bytes, 16);
    const n_tris = readInt(u32, bytes, 20);
    const n_ring = readInt(u32, bytes, 24);
    const n_seam_tris = readInt(u32, bytes, 28);
    const hash = readInt(u64, bytes, 32);

    const payload = bytes[header_len..];
    const lens = [_]u64{
        @as(u64, n_cells) * @sizeOf(Cell),
        @as(u64, n_tris) * @sizeOf(Tri),
        @as(u64, n_ring) * @sizeOf(RingCell),
        @as(u64, n_seam_tris) * @sizeOf(SeamKey),
        @as(u64, n_seam_tris) * @sizeOf(Tri),
    };
    var total: u64 = 0;
    for (lens) |l| total += l;
    if (payload.len != total) return error.PayloadLength;
    if (std.hash.Fnv1a_64.hash(payload) != hash) return error.HashMismatch;

    var at: [lens.len + 1]usize = undefined;
    at[0] = header_len;
    for (lens, 0..) |l, i| at[i + 1] = at[i] + @as(usize, @intCast(l));
    var chunk: Chunk = .{
        .coord = .{ .q = readInt(i32, bytes, 8), .r = readInt(i32, bytes, 12) },
        .cells = std.mem.bytesAsSlice(Cell, bytes[at[0]..at[1]]),
        .tris = std.mem.bytesAsSlice(Tri, bytes[at[1]..at[2]]),
        .ring = std.mem.bytesAsSlice(RingCell, bytes[at[2]..at[3]]),
        .seam_keys = std.mem.bytesAsSlice(SeamKey, bytes[at[3]..at[4]]),
        .seam_tris = std.mem.bytesAsSlice(Tri, bytes[at[4]..at[5]]),
    };
    if (@as(u64, n_tris) != @as(u64, n_cells) * tri_sequence) return error.BadCellRun;
    var seam_total: u64 = 0;
    for (chunk.ring) |c| {
        if (c.n_quad_tris % 2 != 0) return error.BadSeamRun; // quads come whole
        seam_total += c.triCount();
    }
    if (seam_total != n_seam_tris) return error.BadSeamRun;
    // A ring cell's quads join it to one own cell: one key, no corner
    // (`ChunkMesh.buildSeams` keeps the pairs whole on that).
    var it = chunk.ringIterator();
    while (it.next()) |item| {
        const quad_keys = item.keys[0..item.cell.n_quad_tris];
        for (quad_keys) |k| if (!k.eql(quad_keys[0]) or k.also() != null) return error.BadSeamRun;
    }
    for (chunk.seam_keys) |k| {
        if (chunk.groupOf(k) != null) continue;
        if (chunk.n_groups == max_seams) return error.TooManySeams;
        chunk.group_buf[chunk.n_groups] = k;
        chunk.n_groups += 1;
    }
    return chunk;
}

/// The chunk's distinct seam keys, in first-seen order: bit `i` of a
/// `SeamMask` stands for `groups()[i]`.
pub fn groups(chunk: *const Chunk) []const SeamKey {
    return chunk.group_buf[0..chunk.n_groups];
}

/// Index of `key` in `groups`, or null.
pub fn groupOf(chunk: *const Chunk, key: SeamKey) ?usize {
    for (chunk.groups(), 0..) |g, i| if (g.eql(key)) return i;
    return null;
}

/// The groups chunk `chunk` should draw now, per `SeamKey.drawn`.
/// @param loaded {anytype} has `fn loaded(Hex) bool`.
/// @returns {SeamMask} bit `i` set when `groups()[i]` is drawn.
pub fn drawnSeams(chunk: *const Chunk, loaded: anytype) SeamMask {
    var mask: SeamMask = 0;
    for (chunk.groups(), 0..) |k, i| {
        if (k.drawn(chunk.coord, loaded)) mask |= @as(SeamMask, 1) << @intCast(i);
    }
    return mask;
}

/// Each ring cell's seam tris in turn, with their keys.
pub const RingIterator = struct {
    chunk: *const Chunk,
    i: usize = 0,
    first: usize = 0,

    pub const Item = struct {
        cell: RingCell,
        /// Its quad tris (pairs), then its junction tris.
        tris: []align(1) const Tri,
        /// Parallel to `tris`.
        keys: []align(1) const SeamKey,
    };

    pub fn next(it: *RingIterator) ?Item {
        if (it.i == it.chunk.ring.len) return null;
        const cell = it.chunk.ring[it.i];
        const n = cell.triCount();
        defer {
            it.i += 1;
            it.first += n;
        }
        return .{ .cell = cell, .tris = it.chunk.seam_tris[it.first..][0..n], .keys = it.chunk.seam_keys[it.first..][0..n] };
    }
};

pub fn ringIterator(chunk: *const Chunk) RingIterator {
    return .{ .chunk = chunk };
}

/// The `tri_sequence` of own cell `i` (an index into `cells`): face first.
pub fn cellTris(chunk: *const Chunk, i: usize) []align(1) const Tri {
    return chunk.tris[i * tri_sequence ..][0..tri_sequence];
}

fn readInt(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

const testing = std.testing;
const test_data = @import("test_data.zig");

test "std's FNV-1a 64 is the generator's (its known vectors)" {
    try testing.expectEqual(0xcbf2_9ce4_8422_2325, std.hash.Fnv1a_64.hash(""));
    try testing.expectEqual(0xaf63_dc4c_8601_ec8c, std.hash.Fnv1a_64.hash("a"));
}

test "parses a real chunk" {
    const bytes = test_data.chunk_bytes;
    const chunk = try parse(bytes);
    try testing.expectEqual(test_data.chunk_coord, chunk.coord);
    try testing.expectEqual(127, chunk.cells.len);
    try testing.expectEqual(6 * 7, chunk.ring.len);
    try testing.expectEqual(bytes.len, header_len + chunk.cells.len * 16 + chunk.ring.len * 4 + chunk.tris.len * 36 + chunk.seam_tris.len * (16 + 36));
    for (chunk.cells, 0..) |cell, i| {
        const tris = chunk.cellTris(i);
        for (tris[0..face_tris]) |t| {
            try testing.expectEqual(tris[0].a, t.a);
            for ([_]Vec3{ t.a, t.b, t.c }) |v| try testing.expectEqual(cell.height, v.y);
        }
        try testing.expect(cell.radius > 0);
    }
}

test "rejects a flipped payload byte (hash mismatch)" {
    var copy = test_data.chunk_bytes.*;
    copy[header_len + 100] ^= 1;
    try testing.expectError(error.HashMismatch, parse(&copy));
}

test "rejects short, wrong-magic, wrong-version and wrong-length files" {
    const bytes = test_data.chunk_bytes;
    try testing.expectError(error.TooShort, parse(bytes[0 .. header_len - 1]));
    try testing.expectError(error.PayloadLength, parse(bytes[0 .. bytes.len - 1]));
    var copy = bytes.*;
    copy[0] = 'X';
    try testing.expectError(error.BadMagic, parse(&copy));
    copy = bytes.*;
    copy[4] = 3;
    try testing.expectError(error.UnsupportedVersion, parse(&copy));
}

test "seams: neighbour owners, every seam tri in a ring cell's run" {
    const chunk = try parse(test_data.chunk_bytes);
    try testing.expect(chunk.groups().len > 6);
    var total: usize = 0;
    var it = chunk.ringIterator();
    while (it.next()) |item| {
        try testing.expectEqual(item.cell.triCount(), item.tris.len);
        // Runs are back to back: each starts where the last one ended.
        try testing.expectEqual(chunk.seam_tris.ptr + total, item.tris.ptr);
        total += item.tris.len;
        // A ring cell's quads all join it to one own cell: same owner, no corner.
        for (item.keys[0..item.cell.n_quad_tris]) |k| {
            try testing.expect(k.eql(item.keys[0]) and k.also() == null);
        }
    }
    try testing.expectEqual(chunk.seam_tris.len, total);
    for (chunk.groups()) |k| {
        // Owners are the 6 neighbouring chunks; a corner's `also` is another.
        try testing.expectEqual(1, Hex.distance(k.owner(), chunk.coord));
        if (k.also()) |a| try testing.expectEqual(1, Hex.distance(a, chunk.coord));
    }
}

test "drawnSeams: all while alone, none once every neighbour is loaded" {
    const chunk = try parse(test_data.chunk_bytes);
    const all = (@as(u32, 1) << @intCast(chunk.groups().len)) - 1;
    try testing.expectEqual(all, chunk.drawnSeams(LoadedSet{ .coords = &.{chunk.coord} }));
    const ring = [1]Hex{chunk.coord} ++ chunk.coord.neighbors();
    try testing.expectEqual(0, chunk.drawnSeams(LoadedSet{ .coords = &ring }));
}

/// `q,r` as a Hex.
fn parseHex(t: []const u8) !Hex {
    var it = std.mem.splitScalar(u8, t, ',');
    const q = try std.fmt.parseInt(i32, it.next() orelse return error.BadRow, 10);
    const r = try std.fmt.parseInt(i32, it.next() orelse return error.BadRow, 10);
    return .{ .q = q, .r = r };
}

test "SeamKey.drawn follows apicult's table (testdata/entangled_seam_drawn.tsv)" {
    var rows: usize = 0;
    var lines = std.mem.splitScalar(u8, test_data.seam_drawn_table, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const carrier = try parseHex(f.next().?);
        const owner = try parseHex(f.next().?);
        const also_t = f.next().?;
        const also = if (std.mem.eql(u8, also_t, "-")) owner else try parseHex(also_t);
        var loaded_buf: [8]Hex = undefined;
        var n: usize = 0;
        const loaded_t = f.next().?;
        if (!std.mem.eql(u8, loaded_t, "-")) {
            var hs = std.mem.splitScalar(u8, loaded_t, ';');
            while (hs.next()) |h| : (n += 1) loaded_buf[n] = try parseHex(h);
        }
        const want = std.mem.eql(u8, f.next().?, "true");
        const key: SeamKey = .{ .owner_q = owner.q, .owner_r = owner.r, .also_q = also.q, .also_r = also.r };
        try testing.expectEqual(want, key.drawn(carrier, LoadedSet{ .coords = loaded_buf[0..n] }));
        rows += 1;
    }
    try testing.expect(rows >= 10);
}

/// The bytes of `item`'s keys in `copy`, the buffer `chunk` was parsed from.
fn keyBytes(copy: []u8, item: RingIterator.Item) []u8 {
    const at = @intFromPtr(item.keys.ptr) - @intFromPtr(copy.ptr);
    return copy[at..][0 .. item.keys.len * @sizeOf(SeamKey)];
}

fn resign(copy: []u8) void {
    std.mem.writeInt(u64, copy[32..40], std.hash.Fnv1a_64.hash(copy[header_len..]), .little);
}

test "rejects more distinct seam keys than a SeamMask holds" {
    var copy = test_data.chunk_bytes.*;
    const chunk = try parse(&copy);
    // Give max_seams + 1 ring cells their own owner (in `owner_q` and
    // `also_q`, so quads stay corner-free).
    var it = chunk.ringIterator();
    var owners: i32 = 0;
    while (owners <= max_seams) {
        const item = it.next().?;
        if (item.keys.len == 0) continue;
        owners += 1;
        const keys = keyBytes(&copy, item);
        for (0..item.keys.len) |t| {
            std.mem.writeInt(i32, keys[t * 16 ..][0..4], 1000 + owners, .little);
            std.mem.writeInt(i32, keys[t * 16 + 8 ..][0..4], 1000 + owners, .little);
        }
    }
    resign(&copy);
    try testing.expectError(error.TooManySeams, parse(&copy));
}

test "rejects a ring cell whose quad tris don't share one key" {
    var copy = test_data.chunk_bytes.*;
    const chunk = try parse(&copy);
    var it = chunk.ringIterator();
    const item = while (it.next()) |item| {
        if (item.cell.n_quad_tris > 0) break item;
    } else unreachable;
    // Give its last quad tri another owner.
    const last = (item.cell.n_quad_tris - 1) * @as(usize, 16);
    std.mem.writeInt(i32, keyBytes(&copy, item)[last..][0..4], 1000, .little);
    resign(&copy);
    try testing.expectError(error.BadSeamRun, parse(&copy));
}

test "rejects tris that aren't a tri_sequence per cell" {
    var copy = test_data.chunk_bytes.*;
    // One tri fewer: the lengths no longer add up.
    std.mem.writeInt(u32, copy[20..24], 14 * 127 - 1, .little);
    try testing.expectError(error.PayloadLength, parse(&copy));
    // 9 cells fewer and 4 tris more: the same bytes (9·16 = 4·36), same hash,
    // but not 14 tris per cell.
    copy = test_data.chunk_bytes.*;
    std.mem.writeInt(u32, copy[16..20], 127 - 9, .little);
    std.mem.writeInt(u32, copy[20..24], 14 * 127 + 4, .little);
    try testing.expectError(error.BadCellRun, parse(&copy));
    var ring_bad = test_data.chunk_bytes.*;
    const chunk = try parse(&ring_bad);
    const ring_at = @intFromPtr(chunk.ring.ptr) - @intFromPtr(&ring_bad);
    std.mem.writeInt(u16, ring_bad[ring_at..][0..2], 1, .little); // an odd quad count
    resign(&ring_bad);
    try testing.expectError(error.BadSeamRun, parse(&ring_bad));
}

//! One terrain chunk's bytes, read in place: the slices point into them,
//! nothing is copied. apicult-ffi's `ac_chunk` writes the format
//! (`apicult-ffi/src/lib.rs`; apicult-desigual-rs wrote the same files up to
//! e59947); keep the two in sync.
//!
//! | part | layout (little-endian) |
//! |---|---|
//! | header (40 B) | `"HXCK"`, `u32 version`, `i32 q`, `i32 r`, `u32 n_cells`, `u32 n_tris`, `u32 n_seams`, `u32 n_seam_tris`, `u64 hash` |
//! | cells | `n_cells × Cell` (24 B) |
//! | tris | `n_tris × Tri`: per cell 6 face tris (centre, rim corner, rim corner), then 2 per gap quad, then junction tris |
//! | seams | `n_seams × Seam` (24 B) |
//! | seam tris | `n_seam_tris × Tri`: per seam its gap-quad tris (pairs), then its junction tris |
//!
//! A seam holds triangles a neighbour chunk (`owner`) owns that touch this
//! one, so this chunk can fill the gap while the owner isn't loaded; draw it
//! only while `Seam.drawn` holds (apicult's consumer rule 1).
//!
//! `hash` is FNV-1a 64 over every byte after the header.
const std = @import("std");
const builtin = @import("builtin");
const Hex = @import("Hex.zig");
const Vec3 = @import("vec.zig").Vec3;
const Chunk = @This();

pub const magic = "HXCK";
/// v3: v1 (apicult's old files) without the partition-line segments, plus seams.
pub const version: u32 = 3;
pub const header_len = 40;
/// Each cell's face fan, first in its run.
pub const face_tris = 6;

/// One cell's record. Its triangles are `tris[first_tri..][0..triCount()]`.
pub const Cell = extern struct {
    q: i32,
    r: i32,
    height: f32,
    radius: f32,
    first_tri: u32,
    n_quads: u8,
    n_junctions: u8,
    _pad: u16,

    pub fn hex(c: Cell) Hex {
        return .{ .q = c.q, .r = c.r };
    }

    /// 6 face tris + 2 per owned gap quad + 1 per owned junction.
    pub fn triCount(c: Cell) u32 {
        return face_tris + 2 * @as(u32, c.n_quads) + c.n_junctions;
    }
};

pub const Tri = extern struct { a: Vec3, b: Vec3, c: Vec3 };

/// Triangles that chunk `owner` owns and that touch this chunk.
pub const Seam = extern struct {
    owner_q: i32,
    owner_r: i32,
    /// The third chunk a corner junction touches, when `has_also`.
    also_q: i32,
    also_r: i32,
    n_quad_tris: u16,
    n_junction_tris: u16,
    has_also: u8,
    _pad: [3]u8,

    /// The chunk that owns these triangles.
    /// @returns {Hex} its coordinate on the chunk lattice; a neighbour of the carrier.
    pub fn owner(s: Seam) Hex {
        return .{ .q = s.owner_q, .r = s.owner_r };
    }

    /// The third chunk a corner junction touches.
    /// @returns {?Hex} its coordinate, or null for a seam between two chunks.
    pub fn also(s: Seam) ?Hex {
        return if (s.has_also != 0) .{ .q = s.also_q, .r = s.also_r } else null;
    }

    /// How many triangles the seam holds.
    /// @returns {u32} its gap-quad tris plus its junction tris.
    pub fn triCount(s: Seam) u32 {
        return @as(u32, s.n_quad_tris) + s.n_junction_tris;
    }

    /// apicult's consumer rule 1: whether chunk `carrier` (whose seams hold
    /// this one) should draw it now. True while no loaded chunk draws these
    /// triangles: the owner isn't loaded, and for a corner the `also` chunk
    /// isn't either, or sorts after the carrier in `(q, r)` order (so exactly
    /// one of two loaded carriers draws it).
    /// @param carrier {Hex} the chunk whose seams hold `s`.
    /// @param loaded {anytype} has `fn loaded(Hex) bool`.
    /// @returns {bool} whether to draw `s`.
    pub fn drawn(s: Seam, carrier: Hex, loaded: anytype) bool {
        if (loaded.loaded(s.owner())) return false;
        const a = s.also() orelse return true;
        return !loaded.loaded(a) or carrier.q < a.q or (carrier.q == a.q and carrier.r < a.r);
    }
};

/// Which chunks are loaded, for `Seam.drawn`: a plain list, searched in
/// order (a few dozen chunks at most).
pub const LoadedSet = struct {
    coords: []const Hex,

    pub fn loaded(l: LoadedSet, c: Hex) bool {
        return Hex.indexOf(l.coords, c) != null;
    }
};

/// Most seams a chunk may have, so a set of them fits in a `SeamMask`.
/// apicult makes at most 12: 6 neighbour owners and 6 corners.
pub const max_seams = 64;
/// Bit `i` stands for `seams[i]`.
pub const SeamMask = u64;

comptime {
    // The file is little-endian and read in place.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Cell) == 24 and @sizeOf(Tri) == 36 and @sizeOf(Seam) == 24);
}

coord: Hex,
// align(1): the bytes come from apicult-ffi's `Box<[u8]>` or @embedFile, with
// no alignment promise. Every target we build for reads unaligned f32s.
cells: []align(1) const Cell,
tris: []align(1) const Tri,
seams: []align(1) const Seam,
/// Every seam's tris, in `seams` order.
seam_tris: []align(1) const Tri,

pub const Error = error{ TooShort, BadMagic, UnsupportedVersion, PayloadLength, HashMismatch, BadCellRun, BadSeamRun, TooManySeams };

/// Validates `bytes` (header, payload length, hash, cell and seam runs) and returns
/// views into it. `bytes` must outlive the result.
pub fn parse(bytes: []const u8) Error!Chunk {
    if (bytes.len < header_len) return error.TooShort;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
    if (readInt(u32, bytes, 4) != version) return error.UnsupportedVersion;
    const n_cells = readInt(u32, bytes, 16);
    const n_tris = readInt(u32, bytes, 20);
    const n_seams = readInt(u32, bytes, 24);
    if (n_seams > max_seams) return error.TooManySeams;
    const n_seam_tris = readInt(u32, bytes, 28);
    const hash = readInt(u64, bytes, 32);

    const payload = bytes[header_len..];
    const lens = [_]u64{
        @as(u64, n_cells) * @sizeOf(Cell),
        @as(u64, n_tris) * @sizeOf(Tri),
        @as(u64, n_seams) * @sizeOf(Seam),
        @as(u64, n_seam_tris) * @sizeOf(Tri),
    };
    if (payload.len != lens[0] + lens[1] + lens[2] + lens[3]) return error.PayloadLength;
    if (std.hash.Fnv1a_64.hash(payload) != hash) return error.HashMismatch;

    // Checked above to fit in the payload, so these fit in usize (wasm32 too).
    const tris_at: usize = @intCast(header_len + lens[0]);
    const seams_at: usize = tris_at + @as(usize, @intCast(lens[1]));
    const seam_tris_at: usize = seams_at + @as(usize, @intCast(lens[2]));
    const chunk: Chunk = .{
        .coord = .{ .q = readInt(i32, bytes, 8), .r = readInt(i32, bytes, 12) },
        .cells = std.mem.bytesAsSlice(Cell, bytes[header_len..tris_at]),
        .tris = std.mem.bytesAsSlice(Tri, bytes[tris_at..seams_at]),
        .seams = std.mem.bytesAsSlice(Seam, bytes[seams_at..seam_tris_at]),
        .seam_tris = std.mem.bytesAsSlice(Tri, bytes[seam_tris_at..]),
    };
    // Cell runs must tile the tri buffer, so cellTris never reads past it.
    var next: u64 = 0;
    for (chunk.cells) |c| {
        if (c.first_tri != next) return error.BadCellRun;
        next += c.triCount();
    }
    if (next != n_tris) return error.BadCellRun;
    var seam_total: u64 = 0;
    for (chunk.seams) |s| {
        if (s.n_quad_tris % 2 != 0) return error.BadSeamRun; // quads come whole
        seam_total += s.triCount();
    }
    if (seam_total != n_seam_tris) return error.BadSeamRun;
    return chunk;
}

/// Walks the seams in order with their triangles, keeping a running offset
/// into `seam_tris`.
pub const SeamIterator = struct {
    chunk: Chunk,
    i: usize = 0,
    first: usize = 0,

    pub const Item = struct {
        index: usize,
        seam: Seam,
        /// Its gap-quad tris (pairs), then its junction tris.
        tris: []align(1) const Tri,
    };

    /// @returns {?Item} the next seam and its tris, or null after the last.
    pub fn next(it: *SeamIterator) ?Item {
        if (it.i == it.chunk.seams.len) return null;
        const seam = it.chunk.seams[it.i];
        const n = seam.triCount();
        defer {
            it.i += 1;
            it.first += n;
        }
        return .{ .index = it.i, .seam = seam, .tris = it.chunk.seam_tris[it.first..][0..n] };
    }
};

/// Every seam with its triangles, in `seams` order.
/// @returns {SeamIterator} the walk; `parse` checked the runs fit.
pub fn seamIterator(chunk: Chunk) SeamIterator {
    return .{ .chunk = chunk };
}

/// The seams this chunk should draw now, by `Seam.drawn`.
/// @param loaded {anytype} has `fn loaded(Hex) bool`, e.g. a `LoadedSet`.
/// @returns {SeamMask} bit `i` set when `seams[i]` is drawn.
pub fn drawnSeams(chunk: Chunk, loaded: anytype) SeamMask {
    var mask: SeamMask = 0;
    for (chunk.seams, 0..) |s, i| {
        if (s.drawn(chunk.coord, loaded)) mask |= @as(SeamMask, 1) << @intCast(i);
    }
    return mask;
}

/// The triangles `cell` owns.
pub fn cellTris(chunk: Chunk, cell: Cell) []align(1) const Tri {
    return chunk.tris[cell.first_tri..][0..cell.triCount()];
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
    try testing.expect(chunk.cells.len > 0);
    try testing.expectEqual(bytes.len, header_len + chunk.cells.len * 24 + (chunk.tris.len + chunk.seam_tris.len) * 36 + chunk.seams.len * 24);
    var quads: usize = 0;
    for (chunk.cells) |cell| {
        quads += cell.n_quads;
        const tris = chunk.cellTris(cell);
        // Face fan: every face tri is flat at the cell's height and starts at the centre.
        for (tris[0..face_tris]) |t| {
            try testing.expectEqual(tris[0].a, t.a);
            for ([_]Vec3{ t.a, t.b, t.c }) |v| try testing.expectEqual(cell.height, v.y);
        }
        try testing.expect(cell.radius > 0);
    }
    try testing.expect(quads > 0);
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
    copy[4] = 4;
    try testing.expectError(error.UnsupportedVersion, parse(&copy));
}

test "seams: neighbour owners, all seam tris accounted for" {
    const chunk = try parse(test_data.chunk_bytes);
    try testing.expect(chunk.seams.len > 0);
    var total: usize = 0;
    var it = chunk.seamIterator();
    var i: usize = 0;
    while (it.next()) |item| : (i += 1) {
        const s = item.seam;
        try testing.expectEqual(i, item.index);
        // Owners are the 6 neighbouring chunks; a corner's `also` is another.
        try testing.expectEqual(1, Hex.distance(s.owner(), chunk.coord));
        if (s.also()) |a| try testing.expectEqual(1, Hex.distance(a, chunk.coord));
        try testing.expectEqual(s.triCount(), item.tris.len);
        // Runs are back to back: each starts where the last one ended.
        try testing.expectEqual(chunk.seam_tris.ptr + total, item.tris.ptr);
        total += item.tris.len;
    }
    try testing.expectEqual(chunk.seams.len, i);
    try testing.expectEqual(chunk.seam_tris.len, total);
}

test "drawnSeams: all while alone, none once every neighbour is loaded" {
    const chunk = try parse(test_data.chunk_bytes);
    const all = (@as(SeamMask, 1) << @intCast(chunk.seams.len)) - 1;
    try testing.expectEqual(all, chunk.drawnSeams(LoadedSet{ .coords = &.{chunk.coord} }));
    const ring = [1]Hex{chunk.coord} ++ chunk.coord.neighbors();
    try testing.expectEqual(0, chunk.drawnSeams(LoadedSet{ .coords = &ring }));
}

test "Seam.drawn: once while its owner is away, corners by (q, r) order" {
    const Loaded = LoadedSet;
    const a: Hex = .{ .q = 0, .r = 0 };
    const owner: Hex = .{ .q = 1, .r = 0 };
    const also: Hex = .{ .q = 0, .r = 1 };
    var edge = std.mem.zeroes(Seam);
    edge.owner_q = owner.q;
    try testing.expect(edge.drawn(a, Loaded{ .coords = &.{a} }));
    try testing.expect(!edge.drawn(a, Loaded{ .coords = &.{ a, owner } }));
    var corner = edge;
    corner.has_also = 1;
    corner.also_r = also.r;
    try testing.expect(corner.drawn(a, Loaded{ .coords = &.{a} }));
    // Both carriers loaded: only the one sorting first draws it.
    try testing.expect(corner.drawn(a, Loaded{ .coords = &.{ a, also } }));
    var mirrored = corner;
    mirrored.also_q = a.q;
    mirrored.also_r = a.r;
    try testing.expect(!mirrored.drawn(also, Loaded{ .coords = &.{ a, also } }));
    try testing.expect(!corner.drawn(a, Loaded{ .coords = &.{ a, also, owner } }));
}

test "rejects more seams than a SeamMask holds" {
    var copy = test_data.chunk_bytes.*;
    std.mem.writeInt(u32, copy[24..28], max_seams + 1, .little);
    try testing.expectError(error.TooManySeams, parse(&copy));
}

test "rejects cell runs that don't tile the tris" {
    var copy = test_data.chunk_bytes.*;
    // Bump the second cell's first_tri, then re-sign the payload.
    std.mem.writeInt(u32, copy[header_len + 24 + 16 ..][0..4], 1, .little);
    std.mem.writeInt(u64, copy[32..40], std.hash.Fnv1a_64.hash(copy[header_len..]), .little);
    try testing.expectError(error.BadCellRun, parse(&copy));
}

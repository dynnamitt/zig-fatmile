//! One terrain chunk's bytes, read in place: the slices point into them,
//! nothing is copied. apicult-ffi's `ac_chunk` writes the format
//! (`apicult-ffi/src/lib.rs`; apicult-desigual-rs wrote the same files up to
//! e59947); keep the two in sync.
//!
//! | part | layout (little-endian) |
//! |---|---|
//! | header (40 B) | `"HXCK"`, `u32 version`, `i32 q`, `i32 r`, `u32 n_cells`, `u32 n_tris`, `u32 n_lines`, `u32 0`, `u64 hash` |
//! | cells | `n_cells × Cell` (24 B) |
//! | tris | `n_tris × Tri`: per cell 6 face tris, then 2 per gap quad, then junction tris |
//! | lines | `n_lines × Line`: perimeter segments of the owned gap quads |
//!
//! `hash` is FNV-1a 64 over every byte after the header.
const std = @import("std");
const builtin = @import("builtin");
const Hex = @import("Hex.zig");
const Vec3 = @import("vec.zig").Vec3;
const Chunk = @This();

pub const magic = "HXCK";
pub const version: u32 = 1;
pub const header_len = 40;

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
        return 6 + 2 * @as(u32, c.n_quads) + c.n_junctions;
    }
};

pub const Tri = extern struct { a: Vec3, b: Vec3, c: Vec3 };
pub const Line = extern struct { a: Vec3, b: Vec3 };

comptime {
    // The file is little-endian and read in place.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Cell) == 24 and @sizeOf(Tri) == 36 and @sizeOf(Line) == 24);
}

coord: Hex,
// align(1): the bytes come from apicult-ffi's `Box<[u8]>` or @embedFile, with
// no alignment promise. Every target we build for reads unaligned f32s.
cells: []align(1) const Cell,
tris: []align(1) const Tri,
lines: []align(1) const Line,

pub const Error = error{ TooShort, BadMagic, UnsupportedVersion, PayloadLength, HashMismatch, BadCellRun };

/// Validates `bytes` (header, payload length, hash, cell runs) and returns
/// views into it. `bytes` must outlive the result.
pub fn parse(bytes: []const u8) Error!Chunk {
    if (bytes.len < header_len) return error.TooShort;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
    if (readInt(u32, bytes, 4) != version) return error.UnsupportedVersion;
    const n_cells = readInt(u32, bytes, 16);
    const n_tris = readInt(u32, bytes, 20);
    const n_lines = readInt(u32, bytes, 24);
    const hash = readInt(u64, bytes, 32);

    const payload = bytes[header_len..];
    const cells_len = @as(u64, n_cells) * @sizeOf(Cell);
    const tris_len = @as(u64, n_tris) * @sizeOf(Tri);
    const lines_len = @as(u64, n_lines) * @sizeOf(Line);
    if (payload.len != cells_len + tris_len + lines_len) return error.PayloadLength;
    if (std.hash.Fnv1a_64.hash(payload) != hash) return error.HashMismatch;

    // Checked above to fit in the payload, so these fit in usize (wasm32 too).
    const tris_at: usize = @intCast(header_len + cells_len);
    const lines_at: usize = tris_at + @as(usize, @intCast(tris_len));
    const chunk: Chunk = .{
        .coord = .{ .q = readInt(i32, bytes, 8), .r = readInt(i32, bytes, 12) },
        .cells = std.mem.bytesAsSlice(Cell, bytes[header_len..tris_at]),
        .tris = std.mem.bytesAsSlice(Tri, bytes[tris_at..lines_at]),
        .lines = std.mem.bytesAsSlice(Line, bytes[lines_at..]),
    };
    // Cell runs must tile the tri buffer, so cellTris never reads past it.
    var next: u64 = 0;
    for (chunk.cells) |c| {
        if (c.first_tri != next) return error.BadCellRun;
        next += c.triCount();
    }
    if (next != n_tris) return error.BadCellRun;
    return chunk;
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
    try testing.expectEqual(bytes.len, header_len + chunk.cells.len * 24 + chunk.tris.len * 36 + chunk.lines.len * 24);
    var quads: usize = 0;
    for (chunk.cells) |cell| {
        quads += cell.n_quads;
        const tris = chunk.cellTris(cell);
        // Face fan: every face tri is flat at the cell's height and starts at the centre.
        for (tris[0..6]) |t| {
            try testing.expectEqual(tris[0].a, t.a);
            for ([_]Vec3{ t.a, t.b, t.c }) |v| try testing.expectEqual(cell.height, v.y);
        }
        try testing.expect(cell.radius > 0);
    }
    // Each owned gap quad contributes its 4 perimeter segments.
    try testing.expectEqual(4 * quads, chunk.lines.len);
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
    copy[4] = 2;
    try testing.expectError(error.UnsupportedVersion, parse(&copy));
}

test "rejects cell runs that don't tile the tris" {
    var copy = test_data.chunk_bytes.*;
    // Bump the second cell's first_tri, then re-sign the payload.
    std.mem.writeInt(u32, copy[header_len + 24 + 16 ..][0..4], 1, .little);
    std.mem.writeInt(u64, copy[32..40], std.hash.Fnv1a_64.hash(copy[header_len..]), .little);
    try testing.expectError(error.BadCellRun, parse(&copy));
}

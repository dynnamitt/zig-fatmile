//! `terrain/manifest.json`, written by apicult-desigual-rs `hex-chunks`: the
//! world's settings and one entry per chunk file. Only the fields the game
//! needs are read; the rest are skipped.
const std = @import("std");
const Hex = @import("Hex.zig");
const Manifest = @This();

pub const version: u32 = 1;

pub const Entry = struct {
    coord: Hex,
    /// File name inside `terrain/`.
    file: []const u8,
    /// The payload hash the file was written with (`Chunk.hash`).
    hash: u64,
};

chunk_radius: u32,
/// Centre-to-corner size of a full hex, in metres (`HGridSettings::nominal_hex_radius`).
hex_size: f32,
/// Highest cell height the noise can produce (`HGridSettings::max_height`).
max_height: f32,
/// Sorted by (q, r), as the generator writes them.
chunks: []const Entry,

/// The JSON's shape, as far as we read it.
const Json = struct {
    version: u32,
    chunk_radius: u32,
    settings: struct { nominal_hex_radius: f32, max_height: f32 },
    chunks: []const struct { q: i32, r: i32, file: []const u8, hash: []const u8 },
};

pub const Error = error{ UnsupportedVersion, BadHash, BadChunkRadius, Unsorted } || std.json.ParseError(std.json.Scanner);

/// Parses `json`. Everything returned lives in `arena`; `json` can be freed.
pub fn parse(arena: std.mem.Allocator, json: []const u8) Error!Manifest {
    const doc = try std.json.parseFromSliceLeaky(Json, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    if (doc.version != version) return error.UnsupportedVersion;
    if (doc.chunk_radius == 0) return error.BadChunkRadius;
    const chunks = try arena.alloc(Entry, doc.chunks.len);
    for (doc.chunks, chunks, 0..) |c, *e, i| {
        e.* = .{
            .coord = .{ .q = c.q, .r = c.r },
            .file = c.file, // copied into `arena` (alloc_always): `json` may be freed
            .hash = std.fmt.parseInt(u64, c.hash, 16) catch return error.BadHash,
        };
        if (i > 0 and chunks[i - 1].coord.order(e.coord) != .lt) return error.Unsorted;
    }
    return .{
        .chunk_radius = doc.chunk_radius,
        .hex_size = doc.settings.nominal_hex_radius,
        .max_height = doc.settings.max_height,
        .chunks = chunks,
    };
}

/// The entry for chunk `coord`, or null if the world has no such chunk.
pub fn find(m: Manifest, coord: Hex) ?Entry {
    const i = std.sort.binarySearch(Entry, m.chunks, coord, struct {
        fn order(key: Hex, e: Entry) std.math.Order {
            return key.order(e.coord);
        }
    }.order) orelse return null;
    return m.chunks[i];
}

const testing = std.testing;
const test_data = @import("test_data.zig");
const Chunk = @import("Chunk.zig");

test "parses the real manifest, and its hash matches the chunk file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), test_data.manifest_json);
    try testing.expectEqual(test_data.chunk_radius, m.chunk_radius);
    try testing.expectEqual(test_data.hex_size, m.hex_size);
    try testing.expect(m.max_height > 0);
    const e = m.find(test_data.chunk_coord).?;
    try testing.expectEqualStrings("chunk_0_0.bin", e.file);
    try testing.expectEqual((try Chunk.parse(test_data.chunk_bytes)).hash, e.hash);
    for (m.chunks) |c| try testing.expectEqual(c, m.find(c.coord).?);
    try testing.expectEqual(null, m.find(.{ .q = 1000, .r = 0 }));
}

test "skips unknown fields; rejects bad versions, hashes and order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok =
        \\{"version": 1, "chunk_radius": 2, "extra": [1, 2],
        \\ "settings": {"nominal_hex_radius": 4, "max_height": 20, "radius": 9},
        \\ "chunks": [{"q": -1, "r": 0, "file": "a.bin", "hash": "00000000000000ff", "cells": 3},
        \\            {"q": 0, "r": -1, "file": "b.bin", "hash": "ffffffffffffffff"}]}
    ;
    const owned = try testing.allocator.dupe(u8, ok);
    const m = try parse(a, owned);
    testing.allocator.free(owned); // the manifest must not point into the JSON
    try testing.expectEqualStrings("a.bin", m.chunks[0].file);
    try testing.expectEqual(2, m.chunks.len);
    try testing.expectEqual(0xff, m.chunks[0].hash);
    try testing.expectEqual(std.math.maxInt(u64), m.find(.{ .q = 0, .r = -1 }).?.hash);

    try testing.expectError(error.UnsupportedVersion, parse(a, try std.mem.replaceOwned(u8, a, ok, "\"version\": 1", "\"version\": 2")));
    try testing.expectError(error.BadHash, parse(a, try std.mem.replaceOwned(u8, a, ok, "00000000000000ff", "zz")));
    try testing.expectError(error.BadChunkRadius, parse(a, try std.mem.replaceOwned(u8, a, ok, "\"chunk_radius\": 2", "\"chunk_radius\": 0")));
    try testing.expectError(error.Unsorted, parse(a, try std.mem.replaceOwned(u8, a, ok, "\"q\": -1", "\"q\": 5")));
    try testing.expectError(error.MissingField, parse(a, "{\"version\": 1}"));
}

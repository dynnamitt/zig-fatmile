//! Loads and frees terrain chunks around the player, as `core.streaming`
//! plans: reads `terrain/` with raylib's file loader (natively from the
//! working directory, on web from the preloaded virtual filesystem; the
//! same call either way), parses into `terrain`, uploads a mesh per chunk.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const terrain_render = @import("render/terrain.zig");
const TerrainStream = @This();

pub const dir = "terrain";

/// Chunks within 1 chunk-step are loaded; they are freed past 2.
pub const range: core.streaming.Range = .{ .load = 1, .keep = 2 };
/// Most chunks loaded per frame, so a border crossing never hitches.
pub const loads_per_frame = 2;

const Loaded = struct { coord: core.Hex, bytes: []u8, mesh: rl.Mesh };

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
manifest: core.Manifest,
terrain: core.Terrain,
loaded: std.MultiArrayList(Loaded) = .empty,
/// Chunks that failed to load, so they aren't retried every frame.
broken: std.ArrayList(core.Hex) = .empty,
material: rl.Material,

/// Reads the manifest. Call `deinit` before closing the window.
pub fn init(gpa: std.mem.Allocator) !TerrainStream {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const json = try rl.loadFileData(dir ++ "/manifest.json");
    defer rl.unloadFileData(json);
    const manifest = try core.Manifest.parse(arena.allocator(), json);
    return .{
        .gpa = gpa,
        .arena = arena,
        .manifest = manifest,
        .terrain = .init(gpa, manifest.chunk_radius, manifest.hex_size),
        .material = try rl.loadMaterialDefault(),
    };
}

pub fn deinit(s: *TerrainStream) void {
    while (s.loaded.len > 0) s.unload(0);
    s.loaded.deinit(s.gpa);
    s.broken.deinit(s.gpa);
    s.terrain.deinit();
    rl.unloadMaterial(s.material);
    s.arena.deinit();
}

/// Loads up to `budget` missing chunks round world point `x`, `z` and frees
/// those out of range.
pub fn update(s: *TerrainStream, x: f32, z: f32, budget: usize) void {
    var load_buf: [core.Hex.rangeCount(range.load)]core.Hex = undefined;
    var unload_buf: [core.Hex.rangeCount(range.keep)]core.Hex = undefined;
    const plan = core.streaming.plan(range, s.terrain.chunkAt(x, z), World{ .s = s }, s.loaded.items(.coord), budget, &load_buf, unload_buf[0..s.loaded.len]);
    for (plan.unload) |c| {
        s.unload(core.Hex.indexOf(s.loaded.items(.coord), c).?);
    }
    for (plan.load) |c| s.load(c) catch |err| {
        std.log.err("terrain chunk {d},{d}: {t}", .{ c.q, c.r, err });
        s.broken.append(s.gpa, c) catch {};
    };
}

/// The GPU meshes of every loaded chunk.
pub fn meshes(s: TerrainStream) []const rl.Mesh {
    return s.loaded.items(.mesh);
}

/// What `core.streaming.plan` may load: in the manifest and not broken.
const World = struct {
    s: *const TerrainStream,
    pub fn has(w: World, c: core.Hex) bool {
        return w.s.manifest.find(c) != null and core.Hex.indexOf(w.s.broken.items, c) == null;
    }
};

fn load(s: *TerrainStream, coord: core.Hex) !void {
    const entry = s.manifest.find(coord).?;
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, dir ++ "/{s}", .{entry.file}, 0);
    const bytes = try rl.loadFileData(path);
    errdefer rl.unloadFileData(bytes);
    const chunk = try core.Chunk.parse(bytes);
    if (chunk.hash != entry.hash or !chunk.coord.eql(coord)) return error.ManifestMismatch;

    const cpu = try core.ChunkMesh.build(s.gpa, chunk, .{ .max_height = s.manifest.max_height });
    defer cpu.deinit(s.gpa);
    try s.loaded.ensureUnusedCapacity(s.gpa, 1);
    try s.terrain.insert(chunk);
    s.loaded.appendAssumeCapacity(.{ .coord = coord, .bytes = bytes, .mesh = terrain_render.upload(cpu) });
}

fn unload(s: *TerrainStream, i: usize) void {
    const l = s.loaded.get(i);
    s.terrain.remove(l.coord);
    rl.unloadMesh(l.mesh);
    rl.unloadFileData(l.bytes);
    s.loaded.swapRemove(i);
}

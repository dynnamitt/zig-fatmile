//! Loads and frees terrain chunks around the player, as `core.streaming`
//! plans: generates each with apicult-ffi's `ac_chunk` (Rust, linked into
//! both the native and the web build), parses it into `terrain`, uploads a
//! mesh per chunk. The world has no edge within any walkable distance
//! (`core.Hex.toLowerRes` works in f32, which drifts thousands of km out).
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const terrain_render = @import("render/terrain.zig");
const TerrainStream = @This();

/// Chunks within 1 chunk-step are loaded; they are freed past 2.
pub const range: core.streaming.Range = .{ .load = 1, .keep = 2 };
/// Most chunks loaded per frame, so a border crossing never hitches.
pub const loads_per_frame = 2;

const Loaded = struct { coord: core.Hex, bytes: []u8, mesh: rl.Mesh };

/// apicult-ffi (`apicult-ffi/src/lib.rs`): HXCK bytes of chunk `q`, `r`, freed with `ac_free`.
extern fn ac_chunk(chunk_radius: u32, hex_size: f32, max_height: f32, height_seed: u32, radius_seed: u32, q: i32, r: i32, out_len: *usize) [*]u8;
extern fn ac_free(ptr: [*]u8, len: usize) void;

gpa: std.mem.Allocator,
terrain: core.Terrain,
loaded: std.MultiArrayList(Loaded) = .empty,
/// Chunks that failed to load, so they aren't retried every frame.
broken: std.ArrayList(core.Hex) = .empty,
material: rl.Material,

/// Call `deinit` before closing the window.
pub fn init(gpa: std.mem.Allocator) !TerrainStream {
    return .{
        .gpa = gpa,
        .terrain = .init(gpa, core.world.chunk_radius, core.world.hex_size),
        .material = try terrain_render.loadMaterial(),
    };
}

pub fn deinit(s: *TerrainStream) void {
    while (s.loaded.len > 0) s.unload(0);
    s.loaded.deinit(s.gpa);
    s.broken.deinit(s.gpa);
    s.terrain.deinit();
    rl.unloadMaterial(s.material);
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
        s.broken.append(s.gpa, c) catch std.log.err("out of memory: chunk {d},{d} will be retried", .{ c.q, c.r });
    };
}

/// The GPU meshes of every loaded chunk.
pub fn meshes(s: TerrainStream) []const rl.Mesh {
    return s.loaded.items(.mesh);
}

/// What `core.streaming.plan` may load: any chunk that hasn't failed.
const World = struct {
    s: *const TerrainStream,
    pub fn has(w: World, c: core.Hex) bool {
        return core.Hex.indexOf(w.s.broken.items, c) == null;
    }
};

fn load(s: *TerrainStream, coord: core.Hex) !void {
    const w = core.world;
    var len: usize = 0;
    const bytes = ac_chunk(w.chunk_radius, w.hex_size, w.max_height, w.height_seed, w.radius_seed, coord.q, coord.r, &len)[0..len];
    errdefer ac_free(bytes.ptr, bytes.len);
    const chunk = try core.Chunk.parse(bytes);
    if (!chunk.coord.eql(coord)) return error.WrongChunk;

    const cpu = try core.ChunkMesh.build(s.gpa, chunk, .{});
    defer cpu.deinit(s.gpa);
    try s.loaded.ensureUnusedCapacity(s.gpa, 1);
    try s.terrain.insert(chunk);
    s.loaded.appendAssumeCapacity(.{ .coord = coord, .bytes = bytes, .mesh = terrain_render.upload(cpu) });
}

fn unload(s: *TerrainStream, i: usize) void {
    const l = s.loaded.get(i);
    s.terrain.remove(l.coord);
    rl.unloadMesh(l.mesh);
    ac_free(l.bytes.ptr, l.bytes.len);
    s.loaded.swapRemove(i);
}

//! Loads and frees terrain chunks around the player, as `core.streaming`
//! plans: generates each with apicult-ffi's `ac_chunk` (Rust, linked into
//! both the native and the web build), parses it into `terrain`, uploads a
//! mesh per chunk plus one per seam, and lists what to draw: every chunk's
//! own mesh and the seams `core.Chunk.Seam.drawn` allows, which fill the gaps
//! towards chunks that aren't loaded. The world has no edge within any walkable distance
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

const Loaded = struct {
    coord: core.Hex,
    bytes: []u8,
    /// Views into `bytes`.
    chunk: core.Chunk,
    mesh: rl.Mesh,
    /// One per `chunk.seams` entry.
    seams: []rl.Mesh,
};

/// apicult-ffi (`apicult-ffi/src/lib.rs`): HXCK bytes of chunk `q`, `r`, freed with `ac_free`.
extern fn ac_chunk(chunk_radius: u32, hex_size: f32, max_height: f32, height_seed: u32, radius_seed: u32, q: i32, r: i32, out_len: *usize) [*]u8;
extern fn ac_free(ptr: [*]u8, len: usize) void;

gpa: std.mem.Allocator,
terrain: core.Terrain,
loaded: std.MultiArrayList(Loaded) = .empty,
/// Chunks that failed to load, so they aren't retried every frame.
broken: std.ArrayList(core.Hex) = .empty,
/// What to draw this frame; rebuilt by `update`.
visible: std.ArrayList(rl.Mesh) = .empty,
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
    s.visible.deinit(s.gpa);
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
    s.listVisible() catch std.log.err("out of memory: some terrain isn't drawn this frame", .{});
}

/// The GPU meshes to draw: every loaded chunk's own mesh, and each seam
/// while no loaded chunk draws its triangles.
pub fn meshes(s: TerrainStream) []const rl.Mesh {
    return s.visible.items;
}

/// Which chunks are loaded, for `Seam.drawn`.
const LoadedSet = struct {
    coords: []const core.Hex,
    pub fn loaded(l: LoadedSet, c: core.Hex) bool {
        return core.Hex.indexOf(l.coords, c) != null;
    }
};

fn listVisible(s: *TerrainStream) !void {
    s.visible.clearRetainingCapacity();
    const set: LoadedSet = .{ .coords = s.loaded.items(.coord) };
    for (set.coords, s.loaded.items(.chunk), s.loaded.items(.mesh), s.loaded.items(.seams)) |coord, chunk, mesh, seam_meshes| {
        try s.visible.append(s.gpa, mesh);
        for (chunk.seams, seam_meshes) |seam, m| {
            if (seam.drawn(coord, set)) try s.visible.append(s.gpa, m);
        }
    }
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

    const seams = try s.gpa.alloc(rl.Mesh, chunk.seams.len);
    errdefer s.gpa.free(seams);
    var uploaded: usize = 0;
    errdefer for (seams[0..uploaded]) |m| rl.unloadMesh(m);
    for (seams, 0..) |*m, i| {
        const seam_cpu = try core.ChunkMesh.buildSeam(s.gpa, chunk, i, .{});
        defer seam_cpu.deinit(s.gpa);
        m.* = terrain_render.upload(seam_cpu);
        uploaded += 1;
    }
    const cpu = try core.ChunkMesh.build(s.gpa, chunk, .{});
    defer cpu.deinit(s.gpa);
    try s.loaded.ensureUnusedCapacity(s.gpa, 1);
    try s.terrain.insert(chunk);
    s.loaded.appendAssumeCapacity(.{ .coord = coord, .bytes = bytes, .chunk = chunk, .mesh = terrain_render.upload(cpu), .seams = seams });
}

fn unload(s: *TerrainStream, i: usize) void {
    const l = s.loaded.get(i);
    s.terrain.remove(l.coord);
    rl.unloadMesh(l.mesh);
    for (l.seams) |m| rl.unloadMesh(m);
    s.gpa.free(l.seams);
    ac_free(l.bytes.ptr, l.bytes.len);
    s.loaded.swapRemove(i);
}

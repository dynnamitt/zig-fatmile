//! Loads and frees terrain chunks around the player, as `core.streaming`
//! plans: generates each with apicult-ffi's `ac_chunk` (Rust, linked into
//! both the native and the web build), parses it into `terrain`, uploads its
//! own mesh, and keeps per chunk one mesh of the seams `core.Chunk.Seam.drawn`
//! allows, which fill the gaps towards chunks that aren't loaded. The seam
//! meshes and the draw list (`pieces`) are rebuilt only when a chunk loads or
//! unloads. The world has no edge within any walkable distance
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
    /// Round `mesh`.
    bounds: core.Aabb,
    /// The seams in `seam_mesh`.
    seam_mask: core.Chunk.SeamMask = 0,
    /// One mesh of the seams in `seam_mask`; null while that is 0.
    seam_mesh: ?rl.Mesh = null,
    seam_bounds: core.Aabb = .empty,
};

/// apicult-ffi (`apicult-ffi/src/lib.rs`): HXCK bytes of chunk `q`, `r`, freed
/// with `ac_free`; null (and `out_len` 0) if the generator failed.
extern fn ac_chunk(chunk_radius: u32, hex_size: f32, max_height: f32, height_seed: u32, radius_seed: u32, q: i32, r: i32, out_len: *usize) ?[*]u8;
extern fn ac_free(ptr: [*]u8, len: usize) void;

gpa: std.mem.Allocator,
terrain: core.Terrain,
loaded: std.MultiArrayList(Loaded) = .empty,
/// Chunks that failed to load, so they aren't retried every frame.
broken: std.ArrayList(core.Hex) = .empty,
/// What to draw (before culling); rebuilt when a chunk loads or unloads.
pieces: std.ArrayList(terrain_render.Piece) = .empty,
/// Set when the loaded set changed and `pieces` or a seam mesh is out of date.
stale: bool = false,
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
    s.pieces.deinit(s.gpa);
    s.terrain.deinit();
    rl.unloadMaterial(s.material);
}

/// Loads up to `budget` missing chunks round world point `x`, `z` and frees
/// those out of range; after any change, rebuilds the seam meshes that
/// changed and the draw list.
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
    if (plan.load.len > 0 or plan.unload.len > 0) s.stale = true;
    if (s.stale) s.refresh() catch std.log.err("out of memory: terrain seams or draw list are behind, retrying", .{});
}

/// Rebuilds each chunk's seam mesh whose drawn seams changed, then `pieces`.
/// A chunk whose seam mesh fails to build keeps its old one (its own seams,
/// so still valid) and `stale` stays set, so the next `update` retries. If
/// `pieces` can't be rebuilt it is left empty: it may name freed meshes.
fn refresh(s: *TerrainStream) error{OutOfMemory}!void {
    var complete = true;
    const set: core.Chunk.LoadedSet = .{ .coords = s.loaded.items(.coord) };
    const seam_meshes = s.loaded.items(.seam_mesh);
    const seam_bounds = s.loaded.items(.seam_bounds);
    for (s.loaded.items(.chunk), s.loaded.items(.seam_mask), seam_meshes, seam_bounds) |chunk, *mask, *mesh, *bounds| {
        const want = chunk.drawnSeams(set);
        if (want == mask.*) continue;
        const new: ?rl.Mesh, const new_bounds: core.Aabb = if (want == 0) .{ null, .empty } else blk: {
            const cpu = core.ChunkMesh.buildSeams(s.gpa, chunk, want, .{}) catch {
                complete = false;
                continue;
            };
            defer cpu.deinit(s.gpa);
            break :blk .{ terrain_render.upload(cpu), cpu.bounds() };
        };
        if (mesh.*) |old| rl.unloadMesh(old);
        mask.* = want;
        mesh.* = new;
        bounds.* = new_bounds;
    }

    s.pieces.clearRetainingCapacity();
    try s.pieces.ensureTotalCapacity(s.gpa, s.loaded.len);
    for (s.loaded.items(.mesh), s.loaded.items(.bounds), seam_meshes, seam_bounds) |mesh, bounds, seams, sb| {
        s.pieces.appendAssumeCapacity(.{ .bounds = bounds.join(sb), .own = mesh, .seams = seams });
    }
    if (!complete) return error.OutOfMemory;
    s.stale = false;
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
    const ptr = ac_chunk(w.chunk_radius, w.hex_size, w.max_height, w.height_seed, w.radius_seed, coord.q, coord.r, &len) orelse return error.GeneratorFailed;
    const bytes = ptr[0..len];
    errdefer ac_free(bytes.ptr, bytes.len);
    const chunk = try core.Chunk.parse(bytes);
    if (!chunk.coord.eql(coord)) return error.WrongChunk;

    const cpu = try core.ChunkMesh.build(s.gpa, chunk, .{});
    defer cpu.deinit(s.gpa);
    try s.loaded.ensureUnusedCapacity(s.gpa, 1);
    try s.terrain.insert(chunk);
    // Its seam mesh comes from the next `refresh`.
    s.loaded.appendAssumeCapacity(.{ .coord = coord, .bytes = bytes, .chunk = chunk, .mesh = terrain_render.upload(cpu), .bounds = cpu.bounds() });
}

/// Frees chunk `i`. `pieces` still names its meshes until the next `refresh`.
fn unload(s: *TerrainStream, i: usize) void {
    const l = s.loaded.get(i);
    s.terrain.remove(l.coord);
    rl.unloadMesh(l.mesh);
    if (l.seam_mesh) |m| rl.unloadMesh(m);
    ac_free(l.bytes.ptr, l.bytes.len);
    s.loaded.swapRemove(i);
    s.stale = true;
}

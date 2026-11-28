//! Loads and frees terrain chunks around the player, as `core.streaming`
//! plans: generates each with apicult-ffi's `ac_chunk` (Rust, linked into
//! both the native and the web build), parses it into `terrain`, uploads its
//! own mesh, and keeps per chunk one mesh of the seam tris `core.Chunk.SeamKey.drawn`
//! allows, which fill the gaps towards chunks that aren't loaded. The seam
//! meshes and the draw list (`pieces`) are rebuilt only when a chunk loads or
//! unloads. The world has no edge within any walkable distance
//! (`core.Hex.toLowerRes` works in f32, which drifts thousands of km out).
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const terrain_render = @import("render/terrain.zig");
const TerrainStream = @This();

/// Most chunks loaded per frame, so a border crossing never hitches.
pub const loads_per_frame = core.streaming.crossingLoads(core.streaming.chunk_range);

const Loaded = struct {
    coord: core.Hex,
    bytes: []u8,
    /// Views into `bytes`.
    chunk: core.Chunk,
    mesh: rl.Mesh,
    /// Round `mesh`.
    bounds: core.Aabb,
    /// The seam groups in `seam_mesh`.
    seam_mask: core.Chunk.SeamMask = 0,
    /// One mesh of the seams in `seam_mask`; null while that is 0.
    seam_mesh: ?rl.Mesh = null,
    seam_bounds: core.Aabb = .empty,
};

/// apicult-ffi (`apicult-ffi/src/lib.rs`): HXCK bytes of chunk `q`, `r` with
/// `n_edits` stored edits of its own cells and entangled ring, freed with
/// `ac_free`; null (`out_len` 0, `out_err` an `AcError` code) if apicult
/// can't build it.
extern fn ac_chunk(chunk_radius: u32, hex_size: f32, max_height: f32, height_seed: u32, radius_seed: u32, q: i32, r: i32, edits: ?[*]const core.Edits.Edit, n_edits: usize, out_len: *usize, out_err: *u32) ?[*]u8;
extern fn ac_free(ptr: [*]u8, len: usize) void;

gpa: std.mem.Allocator,
terrain: core.Terrain,
/// The dug cells: every chunk is built from noise plus its edits.
edits: core.Edits,
/// Scratch for one chunk's edits, reused by every `load`.
edit_buf: std.ArrayListUnmanaged(core.Edits.Edit) = .empty,
loaded: std.MultiArrayList(Loaded) = .empty,
/// Chunks that failed to load, so they aren't retried every frame.
broken: std.ArrayList(core.Hex) = .empty,
/// What to draw (before culling); rebuilt when a chunk loads or unloads.
pieces: std.ArrayList(terrain_render.Piece) = .empty,
/// Set when the loaded set changed and `pieces` or a seam mesh is out of date.
stale: bool = false,
/// Whether the current run of failed refreshes was logged, so a lasting
/// shortage logs once, not every frame.
refresh_failure_logged: bool = false,
material: rl.Material,

/// Call `deinit` before closing the window.
pub fn init(gpa: std.mem.Allocator) !TerrainStream {
    return .{
        .gpa = gpa,
        .terrain = .init(gpa, core.world.chunk_radius, core.world.hex_size),
        .edits = .init(gpa, core.world.chunk_radius),
        .material = try terrain_render.loadMaterial(),
    };
}

pub fn deinit(s: *TerrainStream) void {
    while (s.loaded.len > 0) s.unload(0);
    s.loaded.deinit(s.gpa);
    s.broken.deinit(s.gpa);
    s.pieces.deinit(s.gpa);
    s.terrain.deinit();
    s.edits.deinit();
    s.edit_buf.deinit(s.gpa);
    rl.unloadMaterial(s.material);
}

/// Loads up to `budget` missing chunks round world point `x`, `z` and frees
/// those out of range; after any change, rebuilds the seam meshes that
/// changed and the draw list.
pub fn update(s: *TerrainStream, x: f32, z: f32, budget: usize) void {
    var load_buf: [core.Hex.rangeCount(core.streaming.chunk_range.load)]core.Hex = undefined;
    var unload_buf: [core.Hex.rangeCount(core.streaming.chunk_range.keep)]core.Hex = undefined;
    const plan = core.streaming.plan(core.streaming.chunk_range, s.terrain.chunkAt(x, z), World{ .s = s }, s.loaded.items(.coord), budget, &load_buf, unload_buf[0..s.loaded.len]);
    for (plan.unload) |c| {
        s.unload(core.Hex.indexOf(s.loaded.items(.coord), c).?);
    }
    for (plan.load) |c| s.loadOrMarkBroken(c);
    if (!s.stale) return;
    if (s.refresh()) {
        s.refresh_failure_logged = false;
    } else |_| if (!s.refresh_failure_logged) {
        std.log.err("out of memory: some terrain seams or the draw list are behind; retrying each frame", .{});
        s.refresh_failure_logged = true;
    }
}

/// Rebuilds each chunk's seam mesh whose drawn seams changed, then `pieces`.
/// A chunk whose seam mesh fails to build draws no seams until a retry
/// works: its old mesh may hold seams a loaded owner now draws itself, and
/// drawing both would z-fight. `stale` then stays set, so the next `update`
/// retries. If `pieces` can't be rebuilt it is left empty: it may name
/// freed meshes.
fn refresh(s: *TerrainStream) error{OutOfMemory}!void {
    var complete = true;
    const set: core.Chunk.LoadedSet = .{ .coords = s.loaded.items(.coord) };
    const seam_meshes = s.loaded.items(.seam_mesh);
    const seam_bounds = s.loaded.items(.seam_bounds);
    for (s.loaded.items(.chunk), s.loaded.items(.seam_mask), seam_meshes, seam_bounds) |chunk, *mask, *mesh, *bounds| {
        const want = chunk.drawnSeams(set);
        if (want == mask.*) continue;
        if (mesh.*) |old| rl.unloadMesh(old);
        mask.* = 0;
        mesh.* = null;
        bounds.* = .empty;
        if (want == 0) continue;
        const cpu = core.ChunkMesh.buildSeams(s.gpa, &chunk, want, .{}) catch {
            complete = false;
            continue;
        };
        defer cpu.deinit(s.gpa);
        mask.* = want;
        mesh.* = terrain_render.upload(cpu);
        bounds.* = cpu.bounds();
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

/// Loads `coord`, or logs why not and lists it in `broken`.
fn loadOrMarkBroken(s: *TerrainStream, coord: core.Hex) void {
    s.load(coord) catch |err| {
        std.log.err("terrain chunk {d},{d}: {t}", .{ coord.q, coord.r, err });
        s.broken.append(s.gpa, coord) catch std.log.err("out of memory: chunk {d},{d} will be retried", .{ coord.q, coord.r });
    };
}

fn load(s: *TerrainStream, coord: core.Hex) !void {
    const w = core.world;
    s.edit_buf.clearRetainingCapacity();
    try s.edits.forChunk(coord, &s.edit_buf, s.gpa);
    var len: usize = 0;
    var err: u32 = 0;
    const edits = s.edit_buf.items;
    const ptr = ac_chunk(w.chunk_radius, w.hex_size, w.max_height, w.height_seed, w.radius_seed, coord.q, coord.r, edits.ptr, edits.len, &len, &err) orelse {
        std.log.err("apicult can't build chunk {d},{d}: error {d} (apicult-ffi's AcError)", .{ coord.q, coord.r, err });
        return error.GeneratorFailed;
    };
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
    s.stale = true;
}

/// Digs `cell`: stores it `core.Edits.dig_depth` lower (down to
/// `core.Edits.min_height`) and rebuilds every loaded chunk whose layout
/// holds it, 1 to 3 (apicult's consumer rule 3), each from noise plus its
/// edits. The draw list is refreshed before returning, so the next draw is
/// current. Call it between ECS steps, never during one (systems read the
/// terrain).
/// @param cell {core.Hex} a loaded cell; any other is ignored.
pub fn dig(s: *TerrainStream, cell: core.Hex) error{OutOfMemory}!void {
    const current = s.terrain.cellHeight(cell) orelse return;
    try s.edits.set(cell, core.Edits.height, core.Edits.dug(current));
    var buf: [3]core.Hex = undefined;
    for (core.Edits.chunksHolding(cell, core.world.chunk_radius, &buf)) |c| {
        const i = core.Hex.indexOf(s.loaded.items(.coord), c) orelse continue;
        s.unload(i);
        s.loadOrMarkBroken(c);
    }
    // On failure `pieces` is left empty and `stale` set: the next `update` retries.
    s.refresh() catch std.log.err("out of memory: terrain draw list is behind after a dig", .{});
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

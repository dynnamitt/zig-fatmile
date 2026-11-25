//! A chunk's renderable triangles, as flat vertex arrays ready for a GPU
//! upload: terrain tris coloured by height with the sun's light baked in per
//! triangle, and per vertex its distances to the two cell rims of the gap
//! quad it lies in, from which the terrain shader paints the partition lines
//! into the gaps, against each cell's rim. Faces stay clean.
const std = @import("std");
const Chunk = @import("Chunk.zig");
const Vec3 = @import("vec.zig").Vec3;
const palette = @import("palette.zig");
const world = @import("world.zig");
const ChunkMesh = @This();

/// Rim distance on faces and junction tris: far past any line width.
pub const no_rim = 1e3;

pub const Style = struct {
    /// Height that maps to the top of the colour ramp.
    max_height: f32 = world.max_height,
    /// Direction towards the sun; baked into vertex colours.
    sun: Vec3 = .{ .x = 0.4, .y = 1, .z = 0.25 },
    /// Light on faces turned away from the sun.
    ambient: f32 = 0.55,
};

/// 3 floats per vertex.
positions: []f32,
/// RGBA bytes per vertex.
colors: []u8,
/// 2 floats per vertex (a GPU texcoord). On a gap quad: the distances in
/// metres to the quad's two rim edges (the owning cell's, then its
/// neighbour's); elsewhere `no_rim` twice.
rims: []f32,

/// A gap quad's two rim edges, each a segment along one cell's side.
const Rims = [2][2]Vec3;

pub fn vertexCount(m: ChunkMesh) usize {
    return m.positions.len / 3;
}

/// The mesh of `chunk`'s own triangles.
pub fn build(allocator: std.mem.Allocator, chunk: Chunk, style: Style) error{OutOfMemory}!ChunkMesh {
    var w: Writer = try .init(allocator, chunk.tris.len, style);
    for (chunk.cells) |cell| w.run(chunk.cellTris(cell), Chunk.face_tris, 2 * @as(usize, cell.n_quads));
    std.debug.assert(w.n == chunk.tris.len);
    return w.mesh;
}

/// The mesh of `chunk`'s seam `i`: gap quads and junctions only, no faces.
pub fn buildSeam(allocator: std.mem.Allocator, chunk: Chunk, i: usize, style: Style) error{OutOfMemory}!ChunkMesh {
    const tris = chunk.seamTris(i);
    var w: Writer = try .init(allocator, tris.len, style);
    w.run(tris, 0, chunk.seams[i].n_quad_tris);
    return w.mesh;
}

pub fn deinit(m: ChunkMesh, allocator: std.mem.Allocator) void {
    allocator.free(m.positions);
    allocator.free(m.colors);
    allocator.free(m.rims);
}

/// The rim edges of the gap quad `[a,b,c], [a,c,d]`: `d`–`a` lies along the
/// owning cell's side and `b`–`c` along its neighbour's (`a`–`b` and `c`–`d`
/// bridge the gap), as apicult's `owned_tris_into` emits it.
fn quadRims(pair: [2]Chunk.Tri) Rims {
    return .{ .{ pair[1].c, pair[0].a }, .{ pair[0].b, pair[0].c } };
}

/// Distance from `p` to the line through `l[0]` and `l[1]`.
fn lineDistance(p: Vec3, l: [2]Vec3) f32 {
    const dir = l[1].sub(l[0]);
    const len = dir.length();
    return if (len == 0) p.sub(l[0]).length() else p.sub(l[0]).cross(dir).length() / len;
}

/// A triangle wound counter-clockwise seen from above (GL's front face), and
/// its unit normal, which then points up. The generator's tris don't all
/// wind the same way, and the GPU culls triangles facing away.
pub const UpTri = struct { tri: Chunk.Tri, normal: Vec3 };

pub fn upFacing(t: Chunk.Tri) UpTri {
    const n = t.b.sub(t.a).cross(t.c.sub(t.a));
    if (n.y >= 0) return .{ .tri = t, .normal = n.normalize() };
    return .{ .tri = .{ .a = t.a, .b = t.c, .c = t.b }, .normal = n.scale(-1).normalize() };
}

const Writer = struct {
    mesh: ChunkMesh,
    sun: Vec3,
    style: Style,
    n: usize = 0,

    fn init(allocator: std.mem.Allocator, n_tris: usize, style: Style) error{OutOfMemory}!Writer {
        const n = n_tris * 3;
        const positions = try allocator.alloc(f32, n * 3);
        errdefer allocator.free(positions);
        const colors = try allocator.alloc(u8, n * 4);
        errdefer allocator.free(colors);
        const rims = try allocator.alloc(f32, n * 2);
        return .{ .mesh = .{ .positions = positions, .colors = colors, .rims = rims }, .sun = style.sun.normalize(), .style = style };
    }

    /// Writes a run of tris: `faces` face tris, then `quad_tris` gap-quad
    /// tris in `[a,b,c], [a,c,d]` pairs, then junction tris.
    fn run(w: *Writer, tris: []align(1) const Chunk.Tri, faces: usize, quad_tris: usize) void {
        const quads = tris[faces..][0..quad_tris];
        for (tris, 0..) |t, i| {
            const up = upFacing(t);
            const avg = (t.a.y + t.b.y + t.c.y) / 3;
            const light = w.style.ambient + (1 - w.style.ambient) * @max(0, up.normal.dot(w.sun));
            const in_quad = i >= faces and i < faces + quad_tris;
            const rims: ?Rims = if (in_quad) quadRims(quads[(i - faces) & ~@as(usize, 1) ..][0..2].*) else null;
            w.tri(up, palette.shade(palette.ground(avg / w.style.max_height), light), rims);
        }
    }

    /// `rims`: the gap quad's rim edges if the tri is half of one. Each
    /// vertex's distances come from its own position, so winding doesn't matter.
    fn tri(w: *Writer, up: UpTri, color: u32, rims: ?Rims) void {
        for ([_]Vec3{ up.tri.a, up.tri.b, up.tri.c }, 0..) |v, k| {
            const i = w.n * 3 + k;
            w.mesh.positions[i * 3 ..][0..3].* = .{ v.x, v.y, v.z };
            std.mem.writeInt(u32, w.mesh.colors[i * 4 ..][0..4], color, .big); // RGBA byte order
            w.mesh.rims[i * 2 ..][0..2].* = if (rims) |r| .{ lineDistance(v, r[0]), lineDistance(v, r[1]) } else @splat(no_rim);
        }
        w.n += 1;
    }
};

const testing = std.testing;
const test_data = @import("test_data.zig");

test "builds every terrain tri, wound counter-clockwise from above" {
    const chunk = try Chunk.parse(test_data.chunk_bytes);
    const m = try build(testing.allocator, chunk, .{});
    defer m.deinit(testing.allocator);
    try testing.expectEqual(3 * chunk.tris.len, m.vertexCount());
    for (0..m.vertexCount() / 3) |t| {
        const p = m.positions[t * 9 ..][0..9];
        const a: Vec3 = .{ .x = p[0], .y = p[1], .z = p[2] };
        const b: Vec3 = .{ .x = p[3], .y = p[4], .z = p[5] };
        const c: Vec3 = .{ .x = p[6], .y = p[7], .z = p[8] };
        try testing.expect(b.sub(a).cross(c.sub(a)).y >= 0);
    }
    try testing.expectEqual(0xFF, m.colors[3]);
}

test "faces are flat-shaded at their cell's height colour" {
    const chunk = try Chunk.parse(test_data.chunk_bytes);
    const style: Style = .{};
    const m = try build(testing.allocator, chunk, style);
    defer m.deinit(testing.allocator);
    const cell = chunk.cells[0];
    // A flat face: normal straight up, fully lit by the sun's vertical part.
    const up_light = style.ambient + (1 - style.ambient) * style.sun.normalize().y;
    const want = palette.shade(palette.ground(cell.height / style.max_height), up_light);
    const i = cell.first_tri * 3;
    try testing.expectEqual(want, std.mem.readInt(u32, m.colors[i * 4 ..][0..4], .big));
}

test "rims: lines only in gap quads, each vertex on one of the quad's rims" {
    const chunk = try Chunk.parse(test_data.chunk_bytes);
    const m = try build(testing.allocator, chunk, .{});
    defer m.deinit(testing.allocator);
    var quads: usize = 0;
    for (chunk.cells) |cell| {
        const v = cell.first_tri * 3; // the cell's first vertex
        // Faces stay clean.
        for (m.rims[v * 2 ..][0 .. Chunk.face_tris * 6]) |r| try testing.expectEqual(no_rim, r);
        for (0..2 * @as(usize, cell.n_quads)) |q| {
            const qv = v + (Chunk.face_tris + q) * 3;
            for (0..3) |k| {
                const r = m.rims[(qv + k) * 2 ..][0..2];
                // Every quad corner sits on one rim, across the gap from the other.
                try testing.expectApproxEqAbs(0, @min(r[0], r[1]), 1e-4);
                try testing.expect(@max(r[0], r[1]) > 0);
            }
            quads += 1;
        }
        // The owning cell's rim is one of its sides: as long as its radius.
        const pair = chunk.cellTris(cell)[Chunk.face_tris..][0..2].*;
        if (cell.n_quads > 0) try testing.expectApproxEqAbs(cell.radius, quadRims(pair)[0][1].sub(quadRims(pair)[0][0]).length(), 1e-4);
    }
    try testing.expect(quads > 0);
    const j = chunk.cells[0];
    if (j.n_junctions > 0) try testing.expectEqual(no_rim, m.rims[(j.first_tri + j.triCount() - 1) * 3 * 2]);
}

test "seam meshes: every seam tri, lines in its quads, none in its junctions" {
    const chunk = try Chunk.parse(test_data.chunk_bytes);
    var quad_tris: usize = 0;
    for (chunk.seams, 0..) |s, i| {
        const m = try buildSeam(testing.allocator, chunk, i, .{});
        defer m.deinit(testing.allocator);
        try testing.expectEqual(3 * s.triCount(), m.vertexCount());
        for (0..m.vertexCount()) |v| {
            const r = m.rims[v * 2 ..][0..2];
            if (v < 3 * @as(usize, s.n_quad_tris)) {
                try testing.expectApproxEqAbs(0, @min(r[0], r[1]), 1e-4);
            } else {
                try testing.expectEqual(no_rim, r[0]);
            }
        }
        quad_tris += s.n_quad_tris;
    }
    try testing.expect(quad_tris > 0);
}

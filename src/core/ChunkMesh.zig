//! A chunk's renderable triangles, as flat vertex arrays ready for a GPU
//! upload: terrain tris with flat per-triangle normals and colour by height,
//! and per vertex its distance to the cell's rim, from which the terrain
//! shader paints the partition lines onto the surface itself.
const std = @import("std");
const Chunk = @import("Chunk.zig");
const Vec3 = @import("vec.zig").Vec3;
const palette = @import("palette.zig");
const world = @import("world.zig");
const ChunkMesh = @This();

/// Rim distance on gap and junction tris: far past any line width.
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
/// 3 floats per vertex, unit length, the same for a triangle's 3 vertices.
normals: []f32,
/// RGBA bytes per vertex.
colors: []u8,
/// 2 floats per vertex (a GPU texcoord): x is the distance in metres to the
/// rim of the cell whose face this is, `no_rim` off the faces; y is 0.
rims: []f32,

pub fn vertexCount(m: ChunkMesh) usize {
    return m.positions.len / 3;
}

pub fn build(allocator: std.mem.Allocator, chunk: Chunk, style: Style) error{OutOfMemory}!ChunkMesh {
    const n = chunk.tris.len * 3;
    const positions = try allocator.alloc(f32, n * 3);
    errdefer allocator.free(positions);
    const normals = try allocator.alloc(f32, n * 3);
    errdefer allocator.free(normals);
    const colors = try allocator.alloc(u8, n * 4);
    errdefer allocator.free(colors);
    const rims = try allocator.alloc(f32, n * 2);
    const out: ChunkMesh = .{ .positions = positions, .normals = normals, .colors = colors, .rims = rims };

    const sun = style.sun.normalize();
    var w: Writer = .{ .mesh = out };
    for (chunk.cells) |cell| {
        for (chunk.cellTris(cell), 0..) |t, i| {
            const up = upFacing(t);
            const avg = (t.a.y + t.b.y + t.c.y) / 3;
            const light = style.ambient + (1 - style.ambient) * @max(0, up.normal.dot(sun));
            // The first 6 are the face fan: `a` is the centre, `b`–`c` a rim edge.
            const rim: [3]f32 = if (i < 6) .{ rimDistance(t), 0, 0 } else @splat(no_rim);
            w.tri(up, palette.shade(palette.ground(avg / style.max_height), light), rim);
        }
    }
    std.debug.assert(w.n == chunk.tris.len);
    return out;
}

pub fn deinit(m: ChunkMesh, allocator: std.mem.Allocator) void {
    allocator.free(m.positions);
    allocator.free(m.normals);
    allocator.free(m.colors);
    allocator.free(m.rims);
}

/// Distance in the ground plane from `t.a` to the line through `t.b`, `t.c`.
fn rimDistance(t: Chunk.Tri) f32 {
    const ex = t.c.x - t.b.x;
    const ez = t.c.z - t.b.z;
    const len = @sqrt(ex * ex + ez * ez);
    if (len == 0) return 0;
    return @abs(ex * (t.a.z - t.b.z) - ez * (t.a.x - t.b.x)) / len;
}

/// A triangle wound counter-clockwise seen from above (GL's front face), and
/// its unit normal, which then points up. The generator's tris don't all
/// wind the same way, and the GPU culls triangles facing away. `swapped`
/// says `b` and `c` changed places.
pub const UpTri = struct { tri: Chunk.Tri, normal: Vec3, swapped: bool };

pub fn upFacing(t: Chunk.Tri) UpTri {
    const n = t.b.sub(t.a).cross(t.c.sub(t.a));
    if (n.y >= 0) return .{ .tri = t, .normal = n.normalize(), .swapped = false };
    return .{ .tri = .{ .a = t.a, .b = t.c, .c = t.b }, .normal = n.scale(-1).normalize(), .swapped = true };
}

const Writer = struct {
    mesh: ChunkMesh,
    n: usize = 0,

    /// `rim` is per corner of the triangle as the generator wound it.
    fn tri(w: *Writer, up: UpTri, color: u32, rim: [3]f32) void {
        const n = up.normal;
        const rims: [3]f32 = if (up.swapped) .{ rim[0], rim[2], rim[1] } else rim;
        for ([_]Vec3{ up.tri.a, up.tri.b, up.tri.c }, rims, 0..) |v, r, k| {
            const i = w.n * 3 + k;
            w.mesh.positions[i * 3 ..][0..3].* = .{ v.x, v.y, v.z };
            w.mesh.normals[i * 3 ..][0..3].* = .{ n.x, n.y, n.z };
            std.mem.writeInt(u32, w.mesh.colors[i * 4 ..][0..4], color, .big); // RGBA byte order
            w.mesh.rims[i * 2 ..][0..2].* = .{ r, 0 };
        }
        w.n += 1;
    }
};

const testing = std.testing;
const test_data = @import("test_data.zig");

test "builds every terrain tri, normals up and unit" {
    const chunk = try Chunk.parse(test_data.chunk_bytes);
    const m = try build(testing.allocator, chunk, .{});
    defer m.deinit(testing.allocator);
    try testing.expectEqual(3 * chunk.tris.len, m.vertexCount());
    for (0..m.vertexCount() / 3) |t| {
        const p = m.positions[t * 9 ..][0..9];
        const a: Vec3 = .{ .x = p[0], .y = p[1], .z = p[2] };
        const b: Vec3 = .{ .x = p[3], .y = p[4], .z = p[5] };
        const c: Vec3 = .{ .x = p[6], .y = p[7], .z = p[8] };
        // Counter-clockwise from above: the winding normal points up.
        try testing.expect(b.sub(a).cross(c.sub(a)).y >= 0);
        const n = m.normals[t * 9 ..][0..3];
        try testing.expectApproxEqAbs(1, Vec3.length(.{ .x = n[0], .y = n[1], .z = n[2] }), 1e-5);
        try testing.expect(n[1] >= 0);
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
    try testing.expectEqual(1, m.normals[i * 3 + 1]);
}

test "rims: the face centre sits an apothem from the rim, corners on it, gaps off it" {
    const chunk = try Chunk.parse(test_data.chunk_bytes);
    const m = try build(testing.allocator, chunk, .{});
    defer m.deinit(testing.allocator);
    for (chunk.cells) |cell| {
        const v = cell.first_tri * 3; // first vertex of the cell's first face tri
        for (0..6) |t| {
            const rim = m.rims[(v + t * 3) * 2 ..][0..6];
            // The centre is `a`, which upFacing never moves.
            try testing.expectApproxEqAbs(cell.radius * @sqrt(3.0) / 2, rim[0], 1e-4);
            try testing.expectEqual(0, rim[2]);
            try testing.expectEqual(0, rim[4]);
        }
        if (cell.triCount() > 6) try testing.expectEqual(no_rim, m.rims[(v + 18) * 2]);
    }
}

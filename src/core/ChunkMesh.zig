//! A chunk's renderable triangles, as flat vertex arrays ready for a GPU
//! upload: terrain tris with flat per-triangle normals and colour by height,
//! plus each partition line as a thin ribbon of two triangles. Ribbons, not
//! GL lines: WebGL ignores line width, and lines passing behind the camera
//! got clipped away whole.
const std = @import("std");
const Chunk = @import("Chunk.zig");
const Vec3 = @import("vec.zig").Vec3;
const palette = @import("palette.zig");
const world = @import("world.zig");
const ChunkMesh = @This();

pub const Style = struct {
    /// Height that maps to the top of the colour ramp.
    max_height: f32 = world.max_height,
    /// Ribbon width and how far it floats above the edge, in metres.
    line_width: f32 = 0.06,
    line_lift: f32 = 0.04,
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

pub fn vertexCount(m: ChunkMesh) usize {
    return m.positions.len / 3;
}

pub fn build(allocator: std.mem.Allocator, chunk: Chunk, style: Style) error{OutOfMemory}!ChunkMesh {
    const n_tris = chunk.tris.len + 2 * chunk.lines.len;
    const positions = try allocator.alloc(f32, n_tris * 9);
    errdefer allocator.free(positions);
    const normals = try allocator.alloc(f32, n_tris * 9);
    errdefer allocator.free(normals);
    const colors = try allocator.alloc(u8, n_tris * 12);
    const out: ChunkMesh = .{ .positions = positions, .normals = normals, .colors = colors };

    const sun = style.sun.normalize();
    var w: Writer = .{ .mesh = out };
    for (chunk.tris) |t| {
        const up = upFacing(t);
        const avg = (t.a.y + t.b.y + t.c.y) / 3;
        const light = style.ambient + (1 - style.ambient) * @max(0, up.normal.dot(sun));
        w.tri(up, palette.shade(palette.ground(avg / style.max_height), light));
    }
    for (chunk.lines) |l| {
        for (ribbon(l, style.line_width, style.line_lift)) |t| w.tri(upFacing(t), palette.line);
    }
    std.debug.assert(w.n == n_tris);
    return out;
}

pub fn deinit(m: ChunkMesh, allocator: std.mem.Allocator) void {
    allocator.free(m.positions);
    allocator.free(m.normals);
    allocator.free(m.colors);
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

/// Line `l` as two triangles `width` wide, lying flat, `lift` above it.
pub fn ribbon(l: Chunk.Line, width: f32, lift: f32) [2]Chunk.Tri {
    const dir = Vec3.normalize(.{ .x = l.b.x - l.a.x, .y = 0, .z = l.b.z - l.a.z });
    const side: Vec3 = .{ .x = -dir.z * width / 2, .y = lift, .z = dir.x * width / 2 };
    const across: Vec3 = .{ .x = -side.x, .y = lift, .z = -side.z };
    const a0 = l.a.add(side);
    const a1 = l.a.add(across);
    const b0 = l.b.add(side);
    const b1 = l.b.add(across);
    return .{ .{ .a = a0, .b = b0, .c = b1 }, .{ .a = a0, .b = b1, .c = a1 } };
}

const Writer = struct {
    mesh: ChunkMesh,
    n: usize = 0,

    fn tri(w: *Writer, up: UpTri, color: u32) void {
        const n = up.normal;
        for ([_]Vec3{ up.tri.a, up.tri.b, up.tri.c }, 0..) |v, k| {
            const i = w.n * 3 + k;
            w.mesh.positions[i * 3 ..][0..3].* = .{ v.x, v.y, v.z };
            w.mesh.normals[i * 3 ..][0..3].* = .{ n.x, n.y, n.z };
            std.mem.writeInt(u32, w.mesh.colors[i * 4 ..][0..4], color, .big); // RGBA byte order
        }
        w.n += 1;
    }
};

const testing = std.testing;
const test_data = @import("test_data.zig");

test "builds every terrain tri plus two per line, normals up and unit" {
    const chunk = try Chunk.parse(test_data.chunk_bytes);
    const m = try build(testing.allocator, chunk, .{});
    defer m.deinit(testing.allocator);
    try testing.expectEqual(3 * (chunk.tris.len + 2 * chunk.lines.len), m.vertexCount());
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
    // Terrain first, opaque; lines after it, black.
    try testing.expectEqual(0xFF, m.colors[3]);
    const first_line = chunk.tris.len * 3 * 4;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0xFF }, m.colors[first_line..][0..4]);
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

test "ribbon: width across the line, lifted, both tris up-facing" {
    const l: Chunk.Line = .{ .a = .{ .x = 0, .y = 1, .z = 0 }, .b = .{ .x = 2, .y = 1, .z = 0 } };
    const tris = ribbon(l, 0.1, 0.05);
    for (tris) |t| for ([_]Vec3{ t.a, t.b, t.c }) |v| {
        try testing.expectApproxEqAbs(1.05, v.y, 1e-6);
        try testing.expectApproxEqAbs(0.05, @abs(v.z), 1e-6);
    };
    try testing.expect(upFacing(tris[0]).normal.y > 0.99);
    // A degenerate (zero-length) line gives a zero-area ribbon, not NaNs.
    const dot = ribbon(.{ .a = l.a, .b = l.a }, 0.1, 0.05);
    try testing.expect(!std.math.isNan(dot[0].a.x));
}

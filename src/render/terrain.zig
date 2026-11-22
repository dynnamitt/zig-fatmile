//! Chunk meshes on the GPU: one raylib `Mesh` per chunk, uploaded once.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");

/// Uploads `m` and returns the GPU mesh. The CPU arrays aren't kept: the
/// caller frees `m` (raylib's `unloadMesh` then frees only GPU buffers).
pub fn upload(m: core.ChunkMesh) rl.Mesh {
    var mesh = std.mem.zeroes(rl.Mesh);
    mesh.vertexCount = @intCast(m.vertexCount());
    mesh.triangleCount = @intCast(m.vertexCount() / 3);
    mesh.vertices = m.positions.ptr;
    mesh.normals = m.normals.ptr;
    mesh.colors = m.colors.ptr;
    rl.uploadMesh(&mesh, false);
    mesh.vertices = null;
    mesh.normals = null;
    mesh.colors = null;
    return mesh;
}

/// Draws `meshes` (vertex colours, world-space vertices) with `material`.
pub fn draw(meshes: []const rl.Mesh, material: rl.Material) void {
    for (meshes) |m| rl.drawMesh(m, material, rl.Matrix.identity());
}

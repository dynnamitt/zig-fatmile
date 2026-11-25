//! Chunk meshes on the GPU: one raylib `Mesh` per chunk, uploaded once, and
//! the terrain shader. The shader draws the baked vertex colours and paints
//! each cell's partition line onto its face, from the per-vertex rim
//! distance in `core.ChunkMesh.rims`: on the surface, so it can't float
//! above the ground or leave a gap.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");

/// Line width in metres, measured into the face from its rim. Far away the
/// shader widens it to `min_line_px` pixels, so distant lines don't break up.
const line_width: f32 = 0.08;
const min_line_px: f32 = 1.0;

// One shader body for both platforms. The header is picked from the GL
// context raylib actually opened (GLSL 100 on WebGL / GLES 2, 330 on
// desktop GL 3.3), not from the build target.
const vs_es2 = "#version 100\n#define IN attribute\n#define OUT varying\n";
const vs_gl33 = "#version 330\n#define IN in\n#define OUT out\n";
// fwidth needs OES_standard_derivatives on GLES 2 (WebGL 1 has it everywhere).
const fs_es2 = "#version 100\n#extension GL_OES_standard_derivatives : enable\nprecision mediump float;\n#define IN varying\n#define FRAG_COLOR gl_FragColor\n";
const fs_gl33 = "#version 330\n#define IN in\nout vec4 fragOut;\n#define FRAG_COLOR fragOut\n";

const vs_body =
    \\IN vec3 vertexPosition;
    \\IN vec2 vertexTexCoord;
    \\IN vec4 vertexColor;
    \\uniform mat4 mvp;
    \\OUT vec4 color;
    \\OUT float rim;
    \\void main() {
    \\    color = vertexColor;
    \\    rim = vertexTexCoord.x;
    \\    gl_Position = mvp * vec4(vertexPosition, 1.0);
    \\}
;
const fs_body =
    \\IN vec4 color;
    \\IN float rim;
    \\uniform float lineWidth;
    \\uniform float minLinePx;
    \\uniform vec4 lineColor;
    \\void main() {
    \\    float width = max(lineWidth, fwidth(rim) * minLinePx);
    \\    FRAG_COLOR = rim < width ? lineColor : color;
    \\}
;

/// Uploads `m` and returns the GPU mesh. The CPU arrays aren't kept: the
/// caller frees `m` (raylib's `unloadMesh` then frees only GPU buffers).
pub fn upload(m: core.ChunkMesh) rl.Mesh {
    var mesh = std.mem.zeroes(rl.Mesh);
    mesh.vertexCount = @intCast(m.vertexCount());
    mesh.triangleCount = @intCast(m.vertexCount() / 3);
    mesh.vertices = m.positions.ptr;
    mesh.normals = m.normals.ptr;
    mesh.colors = m.colors.ptr;
    mesh.texcoords = m.rims.ptr;
    rl.uploadMesh(&mesh, false);
    mesh.vertices = null;
    mesh.normals = null;
    mesh.colors = null;
    mesh.texcoords = null;
    return mesh;
}

/// The terrain material: raylib's default with the terrain shader. Call
/// after the window opens; `rl.unloadMaterial` frees the shader too.
pub fn loadMaterial() !rl.Material {
    const es: bool = switch (@as(rl.gl.rlGlVersion, @fromBackingInt(@intCast(rl.gl.rlGetVersion())))) {
        .rl_opengl_es_20, .rl_opengl_es_30 => true,
        else => false,
    };
    const shader = try if (es)
        rl.loadShaderFromMemory(vs_es2 ++ vs_body, fs_es2 ++ fs_body)
    else
        rl.loadShaderFromMemory(vs_gl33 ++ vs_body, fs_gl33 ++ fs_body);
    errdefer rl.unloadShader(shader);

    rl.setShaderValue(shader, rl.getShaderLocation(shader, "lineWidth"), &line_width, .float);
    rl.setShaderValue(shader, rl.getShaderLocation(shader, "minLinePx"), &min_line_px, .float);
    const c = rl.getColor(core.palette.line);
    const line_color = [4]f32{ toUnit(c.r), toUnit(c.g), toUnit(c.b), toUnit(c.a) };
    rl.setShaderValue(shader, rl.getShaderLocation(shader, "lineColor"), &line_color, .vec4);

    var material = try rl.loadMaterialDefault();
    material.shader = shader;
    return material;
}

fn toUnit(byte: u8) f32 {
    return @as(f32, @floatFromInt(byte)) / 255;
}

/// Draws `meshes` (vertex colours, world-space vertices) with `material`.
pub fn draw(meshes: []const rl.Mesh, material: rl.Material) void {
    for (meshes) |m| rl.drawMesh(m, material, rl.Matrix.identity());
}

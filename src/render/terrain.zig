//! Chunk meshes on the GPU: one raylib `Mesh` per chunk, uploaded once, and
//! the terrain shader. The shader draws the baked vertex colours and paints
//! the partition lines along all four edges of every gap quad, inside it,
//! from the per-vertex edge distances in `core.ChunkMesh.rims` and
//! `.bridges`: on the surface, so they can't float above the ground, and the
//! faces stay clean.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");

/// Line width in metres, measured into the gap quad from its edges. Far away
/// the shader widens it to `min_line_px` pixels, so distant lines don't break
/// up; its edge is blended over one pixel.
const line_width: f32 = 0.08;
const min_line_px: f32 = 1.0;
/// Line colour by height: `palette.line` in the valleys, blending to
/// `palette.line_high` on the ridges. The blend runs over the band of heights
/// the noise mostly yields (as fractions of `core.world.max_height`).
const line_low: f32 = 0.2;
const line_high: f32 = 0.8;

// One shader body for every backend; the header adapts it to the GLSL that
// raylib's graphics API (rlGetVersion) speaks. The same code on web and
// native: the API decides, not the build target.
const Headers = struct { vs: []const u8, fs: []const u8 };
const glsl_330: Headers = .{
    .vs = "#version 330\n#define IN in\n#define OUT out\n",
    .fs = "#version 330\n#define IN in\nout vec4 fragOut;\n#define FRAG_COLOR fragOut\n",
};
const glsl_120: Headers = .{
    .vs = "#version 120\n#define IN attribute\n#define OUT varying\n",
    .fs = "#version 120\n#define IN varying\n#define FRAG_COLOR gl_FragColor\n",
};
// fwidth needs OES_standard_derivatives on GLES 2 (WebGL 1 has it everywhere).
const glsl_100: Headers = .{
    .vs = "#version 100\n#define IN attribute\n#define OUT varying\n",
    .fs = "#version 100\n#extension GL_OES_standard_derivatives : enable\nprecision mediump float;\n#define IN varying\n#define FRAG_COLOR gl_FragColor\n",
};
const glsl_300es: Headers = .{
    .vs = "#version 300 es\n#define IN in\n#define OUT out\n",
    .fs = "#version 300 es\nprecision mediump float;\n#define IN in\nout vec4 fragOut;\n#define FRAG_COLOR fragOut\n",
};

const vs_body =
    \\IN vec3 vertexPosition;
    \\IN vec2 vertexTexCoord;
    \\IN vec2 vertexTexCoord2;
    \\IN vec4 vertexColor;
    \\uniform mat4 mvp;
    \\OUT vec4 color;
    \\OUT vec2 rims;
    \\OUT vec2 bridges;
    \\OUT float height;
    \\void main() {
    \\    color = vertexColor;
    \\    rims = vertexTexCoord;
    \\    bridges = vertexTexCoord2;
    \\    height = vertexPosition.y;
    \\    gl_Position = mvp * vec4(vertexPosition, 1.0);
    \\}
;
const fs_body =
    \\IN vec4 color;
    \\IN vec2 rims;
    \\IN vec2 bridges;
    \\IN float height;
    \\uniform float lineWidth;
    \\uniform float minLinePx;
    \\uniform vec4 lineColor;
    \\uniform vec4 lineColorHigh;
    \\uniform float lineLow;
    \\uniform float lineHigh;
    \\void main() {
    \\    float d = min(min(rims.x, rims.y), min(bridges.x, bridges.y));
    \\    float px = fwidth(d);
    \\    float width = max(lineWidth, px * minLinePx);
    \\    float up = smoothstep(lineLow, lineHigh, height);
    \\    vec4 line = mix(lineColor, lineColorHigh, up);
    \\    FRAG_COLOR = mix(line, color, smoothstep(width - px, width, d));
    \\}
;

/// Uploads `m` and returns the GPU mesh. The CPU arrays aren't kept: the
/// caller frees `m` (raylib's `unloadMesh` then frees only GPU buffers).
pub fn upload(m: core.ChunkMesh) rl.Mesh {
    var mesh = std.mem.zeroes(rl.Mesh);
    mesh.vertexCount = @intCast(m.vertexCount());
    mesh.triangleCount = @intCast(m.vertexCount() / 3);
    mesh.vertices = m.positions.ptr;
    mesh.colors = m.colors.ptr;
    mesh.texcoords = m.rims.ptr;
    mesh.texcoords2 = m.bridges.ptr;
    rl.uploadMesh(&mesh, false);
    mesh.vertices = null;
    mesh.colors = null;
    mesh.texcoords = null;
    mesh.texcoords2 = null;
    return mesh;
}

/// The terrain material: raylib's default with the terrain shader. Call
/// after the window opens; `rl.unloadMaterial` frees the shader too.
/// @returns {rl.Material} the material; error.NoShaders on raylib's GL 1.1
/// and software backends, error.LoadShader if the shader doesn't compile.
pub fn loadMaterial() !rl.Material {
    const shader = try switch (@as(rl.gl.rlGlVersion, @fromBackingInt(@intCast(rl.gl.rlGetVersion())))) {
        .rl_opengl_33, .rl_opengl_43 => load(glsl_330),
        .rl_opengl_21 => load(glsl_120),
        .rl_opengl_es_20 => load(glsl_100),
        .rl_opengl_es_30 => load(glsl_300es),
        .rl_opengl_11, .rl_opengl_software => error.NoShaders,
    };
    errdefer rl.unloadShader(shader);

    rl.setShaderValue(shader, rl.getShaderLocation(shader, "lineWidth"), &line_width, .float);
    rl.setShaderValue(shader, rl.getShaderLocation(shader, "minLinePx"), &min_line_px, .float);
    const line_color = rl.colorNormalize(rl.getColor(core.palette.line));
    rl.setShaderValue(shader, rl.getShaderLocation(shader, "lineColor"), &line_color, .vec4);
    const line_color_high = rl.colorNormalize(rl.getColor(core.palette.line_high));
    rl.setShaderValue(shader, rl.getShaderLocation(shader, "lineColorHigh"), &line_color_high, .vec4);
    const low = line_low * core.world.max_height;
    const high = line_high * core.world.max_height;
    rl.setShaderValue(shader, rl.getShaderLocation(shader, "lineLow"), &low, .float);
    rl.setShaderValue(shader, rl.getShaderLocation(shader, "lineHigh"), &high, .float);

    var material = try rl.loadMaterialDefault();
    material.shader = shader;
    return material;
}

fn load(comptime h: Headers) !rl.Shader {
    return rl.loadShaderFromMemory(h.vs ++ vs_body, h.fs ++ fs_body);
}

/// Draws `meshes` (vertex colours, world-space vertices) with `material`.
pub fn draw(meshes: []const rl.Mesh, material: rl.Material) void {
    for (meshes) |m| rl.drawMesh(m, material, rl.Matrix.identity());
}

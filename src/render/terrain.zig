//! Chunk meshes on the GPU: per chunk its own mesh, uploaded once, and one
//! mesh of the seams it draws; frustum culling; and the terrain shader. The
//! shader draws the baked vertex colours and paints the partition lines
//! along all four edges of every gap quad, inside it, from the per-vertex
//! edge distances in `core.ChunkMesh.rims` and `.bridges`: on the surface,
//! so they can't float above the ground, and the faces stay clean. Then it
//! fades everything into the horizon haze by distance (`core.sky.fog`).
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const glsl = @import("glsl.zig");

/// Line width in metres, measured into the gap quad from its edges. Far away
/// the shader widens it to `min_line_px` pixels, so distant lines don't break
/// up; its edge is blended over one pixel.
const line_width: f32 = 0.08;
const min_line_px: f32 = 1.0;
/// Line colour by height: `palette.line` in the valleys, blending to
/// `palette.line_high` on the ridges. The blend runs over the band of heights
/// the noise mostly yields, as fractions of `core.world.max_height`.
const line_blend_from: f32 = 0.2;
const line_blend_to: f32 = 0.8;

const vs_body =
    \\IN vec3 vertexPosition;
    \\IN vec2 vertexTexCoord;
    \\IN vec2 vertexTexCoord2;
    \\IN vec4 vertexColor;
    \\uniform mat4 mvp;
    \\uniform vec3 viewPos;
    \\uniform float fogStart;
    \\uniform float fogEnd;
    \\OUT vec4 color;
    \\OUT vec2 rims;
    \\OUT vec2 bridges;
    \\OUT float height;
    \\OUT float fog;
    \\void main() {
    \\    color = vertexColor;
    \\    rims = vertexTexCoord;
    \\    bridges = vertexTexCoord2;
    \\    height = vertexPosition.y;
    \\    // core.sky.fog, per vertex: world positions need the vertex
    \\    // shader's full precision (fragments may be mediump).
    \\    fog = smoothstep(fogStart, fogEnd, length(vertexPosition.xz - viewPos.xz));
    \\    gl_Position = mvp * vec4(vertexPosition, 1.0);
    \\}
;
const fs_body =
    \\IN vec4 color;
    \\IN vec2 rims;
    \\IN vec2 bridges;
    \\IN float height;
    \\IN float fog;
    \\uniform vec4 fogColor;
    \\uniform float lineWidth;
    \\uniform float minLinePx;
    \\uniform vec4 lineColor;
    \\uniform vec4 lineColorHigh;
    \\uniform float lineBlendFrom;
    \\uniform float lineBlendTo;
    \\void main() {
    \\    float d = min(min(rims.x, rims.y), min(bridges.x, bridges.y));
    \\    float px = fwidth(d);
    \\    float width = max(lineWidth, px * minLinePx);
    \\    float up = smoothstep(lineBlendFrom, lineBlendTo, height);
    \\    vec4 line = mix(lineColor, lineColorHigh, up);
    \\    vec4 lit = mix(line, color, smoothstep(width - px, width, d));
    \\    FRAG_COLOR = vec4(mix(lit.rgb, fogColor.rgb, fog), 1.0);
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
/// @returns {rl.Material} the material; see `glsl.load` for its errors.
pub fn loadMaterial() !rl.Material {
    var shader = try glsl.load(vs_body, fs_body);
    errdefer rl.unloadShader(shader);
    // raylib's slot for the camera position; `setEye` writes it each frame.
    shader.locs[@backingInt(rl.ShaderLocationIndex.vector_view)] = rl.getShaderLocation(shader, "viewPos");
    rl.setShaderValue(shader, rl.getShaderLocation(shader, "fogStart"), &core.sky.fog_start, .float);
    rl.setShaderValue(shader, rl.getShaderLocation(shader, "fogEnd"), &core.sky.fog_end, .float);
    const fog_color = glsl.color(core.palette.sky_horizon);
    rl.setShaderValue(shader, rl.getShaderLocation(shader, "fogColor"), &fog_color, .vec4);

    rl.setShaderValue(shader, rl.getShaderLocation(shader, "lineWidth"), &line_width, .float);
    rl.setShaderValue(shader, rl.getShaderLocation(shader, "minLinePx"), &min_line_px, .float);
    const line_color = glsl.color(core.palette.line);
    rl.setShaderValue(shader, rl.getShaderLocation(shader, "lineColor"), &line_color, .vec4);
    const line_color_high = glsl.color(core.palette.line_high);
    rl.setShaderValue(shader, rl.getShaderLocation(shader, "lineColorHigh"), &line_color_high, .vec4);
    const blend_from = line_blend_from * core.world.max_height;
    const blend_to = line_blend_to * core.world.max_height;
    rl.setShaderValue(shader, rl.getShaderLocation(shader, "lineBlendFrom"), &blend_from, .float);
    rl.setShaderValue(shader, rl.getShaderLocation(shader, "lineBlendTo"), &blend_to, .float);

    var material = try rl.loadMaterialDefault();
    material.shader = shader;
    return material;
}

/// Tells the terrain shader where the camera is, for the fog. Call each
/// frame before drawing.
pub fn setEye(material: rl.Material, eye: rl.Vector3) void {
    const s = material.shader;
    rl.setShaderValue(s, s.locs[@backingInt(rl.ShaderLocationIndex.vector_view)], &eye, .vec3);
}

/// One chunk to draw: its own mesh and the seams it draws, culled together.
pub const Piece = struct {
    /// Round both meshes.
    bounds: core.Aabb,
    own: rl.Mesh,
    seams: ?rl.Mesh,
};

/// The current camera's frustum, from rlgl's matrices: call between
/// `beginMode3D` and `endMode3D`.
pub fn viewFrustum() core.Frustum {
    // raymath's multiply(a, b) is b·a as maths, so this is projection·view.
    const m = rl.gl.rlGetMatrixModelview().multiply(rl.gl.rlGetMatrixProjection());
    return .fromMatrix(.{
        .{ m.m0, m.m4, m.m8, m.m12 },
        .{ m.m1, m.m5, m.m9, m.m13 },
        .{ m.m2, m.m6, m.m10, m.m14 },
        .{ m.m3, m.m7, m.m11, m.m15 },
    });
}

/// Draws the `pieces` that touch `frustum` (vertex colours, world-space
/// vertices) with `material`.
/// @returns {usize} how many meshes were drawn.
pub fn draw(pieces: []const Piece, frustum: core.Frustum, material: rl.Material) usize {
    var n: usize = 0;
    for (pieces) |p| {
        if (!frustum.touches(p.bounds)) continue;
        rl.drawMesh(p.own, material, rl.Matrix.identity());
        n += 1;
        if (p.seams) |m| {
            rl.drawMesh(m, material, rl.Matrix.identity());
            n += 1;
        }
    }
    return n;
}

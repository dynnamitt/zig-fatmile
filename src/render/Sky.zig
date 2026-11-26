//! The sky, drawn behind everything: a full-screen quad at the far plane
//! whose shader turns each pixel into a view direction and colours it
//! (horizon haze, mauve, zenith teal; `core.sky.horizon_falloff`), with the
//! sun's disc and glow and the moon's crescent. Draw it last inside
//! `beginMode3D`: the depth test then shades only pixels the terrain left.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const glsl = @import("glsl.zig");
const Sky = @This();

// The quad's corners are already clip-space (x, y), at depth 1: the far
// plane, which passes raylib's LEQUAL test only where nothing was drawn.
// Each vertex unprojects
// its own corner to a ray, at full vertex precision. Rays to points on the
// far plane interpolate linearly across the screen, so the fragments get
// exact directions to normalise.
const vs_body =
    \\IN vec3 vertexPosition;
    \\uniform mat4 invViewProj;
    \\OUT vec3 ray;
    \\void main() {
    \\    vec4 near = invViewProj * vec4(vertexPosition.xy, -1.0, 1.0);
    \\    vec4 far = invViewProj * vec4(vertexPosition.xy, 1.0, 1.0);
    \\    ray = far.xyz / far.w - near.xyz / near.w;
    \\    gl_Position = vec4(vertexPosition.xy, 1.0, 1.0);
    \\}
;
const fs_body =
    \\IN vec3 ray;
    \\uniform vec4 zenith;
    \\uniform vec4 horizon;
    \\uniform vec4 mid;
    \\uniform float falloff;
    \\uniform vec3 sunDir;
    \\uniform vec4 sunColor;
    \\uniform float sunCos;
    \\uniform vec3 moonDir;
    \\uniform vec3 moonShadowDir;
    \\uniform vec4 moonColor;
    \\uniform float moonCos;
    \\// 1 inside the disc of angular radius acos(cosR) round `towards`,
    \\// blended over about a pixel.
    \\float disc(vec3 dir, vec3 towards, float cosR) {
    \\    float c = dot(dir, towards);
    \\    float px = fwidth(c);
    \\    return smoothstep(cosR - px, cosR + px, c);
    \\}
    \\void main() {
    \\    vec3 dir = normalize(ray);
    \\    float t = pow(clamp(dir.y, 0.0, 1.0), falloff);
    \\    vec3 col = t < 0.5 ? mix(horizon.rgb, mid.rgb, t * 2.0) : mix(mid.rgb, zenith.rgb, t * 2.0 - 1.0);
    \\    float up = step(0.0, dir.y);
    \\    float glow = pow(max(dot(dir, sunDir), 0.0), 64.0) * 0.6;
    \\    col = mix(col, sunColor.rgb, up * clamp(disc(dir, sunDir, sunCos) + glow, 0.0, 1.0));
    \\    float crescent = disc(dir, moonDir, moonCos) * (1.0 - disc(dir, moonShadowDir, moonCos));
    \\    col = mix(col, moonColor.rgb, up * crescent);
    \\    FRAG_COLOR = vec4(col, 1.0);
    \\}
;

shader: rl.Shader,
inv_view_proj: i32,

/// Compiles the sky shader and sets everything but the camera. Call after
/// the window opens, and `unload` before it closes.
/// @returns {Sky} the sky; see `glsl.load` for its errors.
pub fn load() !Sky {
    const shader = try glsl.load(vs_body, fs_body);
    const sky = core.sky;
    const p = core.palette;
    glsl.setColor(shader, "zenith", p.sky_zenith);
    glsl.setColor(shader, "horizon", p.sky_horizon);
    glsl.setColor(shader, "mid", p.sky_mid);
    glsl.setFloat(shader, "falloff", sky.horizon_falloff);
    glsl.setVec3(shader, "sunDir", sky.sun);
    glsl.setColor(shader, "sunColor", p.sun);
    glsl.setFloat(shader, "sunCos", @cos(std.math.degreesToRadians(sky.sun_radius)));
    glsl.setVec3(shader, "moonDir", sky.moon);
    glsl.setVec3(shader, "moonShadowDir", sky.moonShadow());
    glsl.setColor(shader, "moonColor", p.moon);
    glsl.setFloat(shader, "moonCos", @cos(std.math.degreesToRadians(sky.moon_radius)));
    return .{ .shader = shader, .inv_view_proj = rl.getShaderLocation(shader, "invViewProj") };
}

pub fn unload(s: Sky) void {
    rl.unloadShader(s.shader);
}

/// Fills every pixel nothing else covered with sky. Call inside
/// `beginMode3D`, after everything else.
/// @param view_proj {rl.Matrix} the camera's, from `glsl.viewProj`.
pub fn draw(s: Sky, view_proj: rl.Matrix) void {
    rl.setShaderValueMatrix(s.shader, s.inv_view_proj, view_proj.invert());
    rl.beginShaderMode(s.shader);
    defer rl.endShaderMode(); // draws the batch with this shader
    rl.gl.rlBegin(rl.gl.rl_quads);
    defer rl.gl.rlEnd();
    // Counter-clockwise, so back-face culling keeps it.
    for ([_][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } }) |c| rl.gl.rlVertex3f(c[0], c[1], 0);
}

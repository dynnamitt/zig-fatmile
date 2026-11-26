//! Shader loading for every raylib backend: one GLSL body per shader, behind
//! a header that adapts it to the GLSL that raylib's graphics API
//! (rlGetVersion) speaks. The same code on web and native: the API decides,
//! not the build target. Bodies use `IN`/`OUT` for varyings and attributes
//! and write `FRAG_COLOR`.
const rl = @import("raylib");
const core = @import("core");

const Headers = struct { vs: [:0]const u8, fs: [:0]const u8 };
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

/// Compiles `vs_body` and `fs_body` behind the current API's header. Call
/// after the window opens.
/// @returns {rl.Shader} the shader; error.NoShaders on raylib's GL 1.1 and
/// software backends, error.LoadShader if it doesn't compile.
pub fn load(comptime vs_body: [:0]const u8, comptime fs_body: [:0]const u8) !rl.Shader {
    return switch (@as(rl.gl.rlGlVersion, @fromBackingInt(@intCast(rl.gl.rlGetVersion())))) {
        .rl_opengl_33, .rl_opengl_43 => with(glsl_330, vs_body, fs_body),
        .rl_opengl_21 => with(glsl_120, vs_body, fs_body),
        .rl_opengl_es_20 => with(glsl_100, vs_body, fs_body),
        .rl_opengl_es_30 => with(glsl_300es, vs_body, fs_body),
        .rl_opengl_11, .rl_opengl_software => error.NoShaders,
    };
}

fn with(comptime h: Headers, comptime vs_body: [:0]const u8, comptime fs_body: [:0]const u8) !rl.Shader {
    return rl.loadShaderFromMemory(h.vs ++ vs_body, h.fs ++ fs_body);
}

/// `c` (0xRRGGBBAA) as the vec4 a colour uniform takes.
pub fn color(c: u32) rl.Vector4 {
    return rl.colorNormalize(rl.getColor(c));
}

pub fn setFloat(shader: rl.Shader, name: [:0]const u8, v: f32) void {
    rl.setShaderValue(shader, rl.getShaderLocation(shader, name), &v, .float);
}

pub fn setVec3(shader: rl.Shader, name: [:0]const u8, v: core.Vec3) void {
    rl.setShaderValue(shader, rl.getShaderLocation(shader, name), &v, .vec3); // extern: 3 packed f32s
}

/// Sets a vec4 uniform to colour `c` (0xRRGGBBAA).
pub fn setColor(shader: rl.Shader, name: [:0]const u8, c: u32) void {
    const v = color(c);
    rl.setShaderValue(shader, rl.getShaderLocation(shader, name), &v, .vec4);
}

/// The current camera's view-projection matrix, from rlgl: call between
/// `beginMode3D` and `endMode3D`. raymath's multiply(a, b) is b·a as
/// maths, so this is projection·view.
pub fn viewProj() rl.Matrix {
    return rl.gl.rlGetMatrixModelview().multiply(rl.gl.rlGetMatrixProjection());
}

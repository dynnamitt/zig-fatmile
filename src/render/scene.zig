//! World-space drawing: the loaded terrain, seen through the player's eyes.
const rl = @import("raylib");
const game = @import("game");
const terrain = @import("terrain.zig");

const p = game.player;

/// Near/far clip planes (m) at ground level. Near is raised from raylib's
/// 0.01 for depth precision at a distance. Both grow with the camera's
/// height (the debug lift), so the ground stays in view from above.
const near = 0.1;
const far = 1000.0;
const near_per_height = 0.001;
const fovy = 70;

/// Camera for a `game.player.View`.
pub fn camera(v: p.View) rl.Camera3D {
    const target = v.eye.add(v.dir);
    return .{
        .position = .{ .x = v.eye.x, .y = v.eye.y, .z = v.eye.z },
        .target = .{ .x = target.x, .y = target.y, .z = target.z },
        .up = .{ .x = 0, .y = 1, .z = 0 },
        .fovy = fovy,
        .projection = .perspective,
    };
}

/// Draws the world.
pub fn draw(cam: rl.Camera3D, meshes: []const rl.Mesh, material: rl.Material) void {
    const height = @max(0, cam.position.y);
    rl.gl.rlSetClipPlanes(@max(near, height * near_per_height), far + height); // read by beginMode3D
    rl.beginMode3D(cam);
    defer rl.endMode3D();
    terrain.draw(meshes, material);
}

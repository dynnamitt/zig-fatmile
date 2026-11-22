//! World-space drawing: the loaded terrain, seen through the player's eyes.
const rl = @import("raylib");
const game = @import("game");
const terrain = @import("terrain.zig");

const p = game.player;

/// Near/far clip planes (m). Near is raised from raylib's 0.01 so the depth
/// buffer keeps the partition ribbons above the ground at a distance.
const near = 0.1;
const far = 1000.0;
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

/// One-time renderer setup, after the window opens.
pub fn init() void {
    rl.gl.rlSetClipPlanes(near, far);
}

/// Draws the world.
pub fn draw(cam: rl.Camera3D, meshes: []const rl.Mesh, material: rl.Material) void {
    rl.beginMode3D(cam);
    defer rl.endMode3D();
    terrain.draw(meshes, material);
}

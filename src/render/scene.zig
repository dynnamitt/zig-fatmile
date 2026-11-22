//! World-space drawing: the loaded terrain, seen through the player's eyes.
const rl = @import("raylib");
const ecs = @import("zflecs");
const core = @import("core");
const game = @import("game");
const terrain = @import("terrain.zig");

const p = game.player;

/// Near/far clip planes (m). Near is raised from raylib's 0.01 so the depth
/// buffer keeps the partition ribbons above the ground at a distance.
pub const near = 0.1;
pub const far = 1000.0;
const fovy = 70;

/// The player's eye, interpolated `alpha` (`FixedClock.alpha`) of the way
/// from the previous step to the latest one. Look isn't interpolated: it
/// would make the mouse lag.
pub fn camera(world: *ecs.world_t, player: ecs.entity_t, alpha: f32) rl.Camera3D {
    const pos = ecs.get(world, player, p.Position).?.at;
    const prev = ecs.get(world, player, p.Previous).?;
    const look = ecs.get(world, player, p.Look).?;
    var eye = prev.at.lerp(pos, alpha);
    eye.y = prev.eye_y + (ecs.get(world, player, p.Eye).?.y - prev.eye_y) * alpha;
    const target = eye.add(core.motion.lookDir(look.yaw, look.pitch));
    return .{
        .position = .{ .x = eye.x, .y = eye.y, .z = eye.z },
        .target = .{ .x = target.x, .y = target.y, .z = target.z },
        .up = .{ .x = 0, .y = 1, .z = 0 },
        .fovy = fovy,
        .projection = .perspective,
    };
}

/// Draws the world.
pub fn draw(cam: rl.Camera3D, meshes: []const rl.Mesh, material: rl.Material) void {
    rl.beginMode3D(cam);
    defer rl.endMode3D();
    terrain.draw(meshes, material);
}

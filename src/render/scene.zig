//! World-space drawing. Placeholder until terrain chunks load (issue #1): a
//! ground grid seen from head height.
const rl = @import("raylib");

const grid_slices = 40;
const grid_spacing = 1.0;

/// Eye 1.7 m above the ground, looking ahead and slightly down.
pub const camera: rl.Camera3D = .{
    .position = .{ .x = 0, .y = 1.7, .z = 6 },
    .target = .{ .x = 0, .y = 0.5, .z = 0 },
    .up = .{ .x = 0, .y = 1, .z = 0 },
    .fovy = 60,
    .projection = .perspective,
};

/// Draws the world from `cam`.
pub fn draw(cam: rl.Camera3D) void {
    rl.beginMode3D(cam);
    defer rl.endMode3D();
    rl.drawGrid(grid_slices, grid_spacing);
}

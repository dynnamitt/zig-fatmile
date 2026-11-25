//! Engine-agnostic building blocks: no raylib, no flecs. Everything here runs
//! under `zig build test` with no window, GPU or ECS world.
pub const FixedClock = @import("FixedClock.zig");
pub const FrameStats = @import("FrameStats.zig");
pub const palette = @import("palette.zig");
pub const Vec3 = @import("vec.zig").Vec3;
pub const Hex = @import("Hex.zig");
pub const Chunk = @import("Chunk.zig");
pub const world = @import("world.zig");
pub const Terrain = @import("Terrain.zig");
pub const ChunkMesh = @import("ChunkMesh.zig");
pub const ground = @import("ground.zig");
pub const streaming = @import("streaming.zig");
pub const motion = @import("motion.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

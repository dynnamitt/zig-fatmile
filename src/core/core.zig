//! Engine-agnostic building blocks: no raylib, no flecs. Everything here runs
//! under `zig build test` with no window, GPU or ECS world.
pub const FixedClock = @import("FixedClock.zig");
pub const FrameStats = @import("FrameStats.zig");
pub const palette = @import("palette.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

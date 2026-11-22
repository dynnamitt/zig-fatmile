//! Game state on the ECS: components, systems and `register`. Imports zflecs
//! and core, never raylib, so it runs under `zig build test`. Systems that
//! change state live here (or in files this one imports); rendering only
//! reads the world, so the renderer can be swapped.
const ecs = @import("zflecs");

pub const flecs = @import("flecs.zig");

/// Registers every component and system on `world`. Empty until the first
/// world iteration (issue #1) adds terrain and the player.
pub fn register(world: *ecs.world_t) void {
    _ = world;
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "register leaves a world that steps" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    try @import("std").testing.expect(ecs.progress(world, @import("core").FixedClock.step_dt));
}

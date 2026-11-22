//! Game state on the ECS: components, systems and `register`. Imports zflecs
//! and core, never raylib, so it runs under `zig build test`. Systems that
//! change state live here (or in files this one imports); rendering only
//! reads the world, so the renderer can be swapped.
const ecs = @import("zflecs");
const core = @import("core");

pub const flecs = @import("flecs.zig");
pub const player = @import("player.zig");

/// Registers every component and system on `world`. `ground` is what the
/// player walks on; it must outlive `world` and only change between
/// `ecs.progress` calls.
pub fn register(world: *ecs.world_t, ground: *const core.ground.Ground) void {
    player.register(world, ground);
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "register leaves a world that steps" {
    const Flat = struct {
        pub fn heightAt(_: *const @This(), _: f32, _: f32) ?f32 {
            return 0;
        }
    };
    const ground: core.ground.Ground = .of(Flat, &.{});
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world, &ground);
    _ = player.spawn(world, core.Vec3.zero, 0);
    try @import("std").testing.expect(ecs.progress(world, core.FixedClock.step_dt));
}

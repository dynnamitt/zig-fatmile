//! The player: components, the two systems that steer and walk it at fixed
//! steps, and `spawn`. Input lives in the exe and only writes `Intent`.
const std = @import("std");
const ecs = @import("zflecs");
const core = @import("core");
const flecs = @import("flecs.zig");

const Vec3 = core.Vec3;
const motion = core.motion;

/// Tuning. 1 world unit = 1 m.
pub const walk_speed: f32 = 4.5; // m/s
/// Steepest climb allowed, rise over run (1 = 45°). Downhill is never limited.
pub const max_climb: f32 = 1.0;
pub const eye_height: f32 = 1.7; // m above the ground
/// How far the shovel reaches from the eye, in hex sizes (`core.world.hex_size`).
pub const reach_factor: f32 = 1.5;
pub const reach: f32 = reach_factor * core.world.hex_size; // m
/// Eye smoothing rate (1/s): how fast the eye follows the ground up and down
/// between hexes. Higher is stiffer.
pub const eye_rate: f32 = 12;

/// Marks the player entity.
pub const Player = struct {};

/// Where the feet are: on the ground, always.
pub const Position = struct { at: Vec3 };

/// Horizontal walking velocity, m/s, from `Intent` and `Look`.
pub const Velocity = struct { x: f32 = 0, z: f32 = 0 };

/// View direction, radians (see `core.motion`).
pub const Look = struct { yaw: f32 = 0, pitch: f32 = 0 };

/// Smoothed eye height (world y).
pub const Eye = struct { y: f32 };

/// Last step's position and eye, so rendering can interpolate (`FixedClock.alpha`).
pub const Previous = struct { at: Vec3, eye_y: f32 };

/// What the player wants this step; written by the exe from mouse, keys and
/// gamepad, read by `steer`.
pub const Intent = struct {
    /// Walk input, -1..1: x is right, y is forward.
    walk: [2]f32 = .{ 0, 0 },
    /// Look change (yaw, pitch) in radians not yet applied, e.g. mouse motion.
    /// The next step applies it all and clears it.
    look_delta: [2]f32 = .{ 0, 0 },
    /// Look speed (yaw, pitch) in radians per second, e.g. a stick.
    look_rate: [2]f32 = .{ 0, 0 },
};

pub fn register(world: *ecs.world_t, ground: *const core.ground.Ground) void {
    ecs.TAG(world, Player);
    ecs.COMPONENT(world, Position);
    ecs.COMPONENT(world, Velocity);
    ecs.COMPONENT(world, Look);
    ecs.COMPONENT(world, Eye);
    ecs.COMPONENT(world, Previous);
    ecs.COMPONENT(world, Intent);
    flecs.addSystem(world, "steer", ecs.PreUpdate, steer, .{});
    // ground is only read: safe on any worker.
    flecs.addSystem(world, "walk", ecs.OnUpdate, walk, .{ .ctx = ground });
}

/// Spawns the player standing at `at` (on the ground), looking along `yaw`.
pub fn spawn(world: *ecs.world_t, at: Vec3, yaw: f32) ecs.entity_t {
    const e = ecs.new_id(world);
    ecs.add(world, e, Player);
    flecs.set(world, e, Position, .{ .at = at });
    flecs.set(world, e, Velocity, .{});
    flecs.set(world, e, Look, .{ .yaw = yaw });
    flecs.set(world, e, Eye, .{ .y = at.y + eye_height });
    flecs.set(world, e, Previous, .{ .at = at, .eye_y = at.y + eye_height });
    flecs.set(world, e, Intent, .{});
    return e;
}

/// What the player sees: eye position and unit view direction.
pub const View = struct { eye: Vec3, dir: Vec3 };

/// The player's view, the eye interpolated `alpha` (`FixedClock.alpha`) of
/// the way from the previous step to the latest one. Look isn't
/// interpolated: it would make the mouse lag. Mouse motion not yet applied
/// by a step is added, so frames between steps (displays over 60 Hz) still
/// turn smoothly.
pub fn view(world: *ecs.world_t, e: ecs.entity_t, alpha: f32) View {
    const pos = ecs.get(world, e, Position).?.at;
    const prev = ecs.get(world, e, Previous).?;
    const look = ecs.get(world, e, Look).?;
    var eye = prev.at.lerp(pos, alpha);
    eye.y = std.math.lerp(prev.eye_y, ecs.get(world, e, Eye).?.y, alpha);
    const pending = ecs.get(world, e, Intent).?.look_delta;
    return .{ .eye = eye, .dir = motion.lookDir(look.yaw + pending[0], motion.clampPitch(look.pitch + pending[1])) };
}

/// Applies look input, then turns walk input into a velocity along the view.
fn steer(it: *ecs.iter_t, intents: []Intent, looks: []Look, vels: []Velocity) void {
    for (intents, looks, vels) |*in, *look, *vel| {
        look.yaw += in.look_delta[0] + in.look_rate[0] * it.delta_time;
        look.yaw = @mod(look.yaw, std.math.tau); // keep precision over long sessions
        look.pitch = motion.clampPitch(look.pitch + in.look_delta[1] + in.look_rate[1] * it.delta_time);
        in.look_delta = .{ 0, 0 };
        const v = motion.walkVelocity(look.yaw, in.walk[0], in.walk[1], walk_speed);
        vel.* = .{ .x = v[0], .z = v[1] };
    }
}

/// Moves along the velocity under the ground rule and smooths the eye.
fn walk(it: *ecs.iter_t, positions: []Position, prevs: []Previous, eyes: []Eye, vels: []const Velocity) void {
    const ground: *const core.ground.Ground = @ptrCast(@alignCast(it.ctx.?));
    const dt = it.delta_time;
    for (positions, prevs, eyes, vels) |*pos, *prev, *eye, vel| {
        prev.* = .{ .at = pos.at, .eye_y = eye.y };
        pos.at = core.ground.walk(ground.*, pos.at, vel.x * dt, vel.z * dt, max_climb);
        eye.y = motion.approach(eye.y, pos.at.y + eye_height, eye_rate, dt);
    }
}

const testing = std.testing;

/// Test ground: level at 0 for x < 1, a wall-high step of `step` beyond.
const Step = struct {
    step: f32,
    pub fn heightAt(self: *const Step, x: f32, _: f32) ?f32 {
        return if (x < 1) 0 else self.step;
    }
    fn ground(self: *const Step) core.ground.Ground {
        return .of(Step, self);
    }
};

fn testWorld(g: *const core.ground.Ground) *ecs.world_t {
    const world = ecs.init();
    register(world, g);
    return world;
}

const step_dt = core.FixedClock.step_dt;

test "walks forward at walk_speed along the view" {
    const s: Step = .{ .step = 0 };
    const g = s.ground();
    const world = testWorld(&g);
    defer _ = ecs.fini(world);
    // yaw π/2 looks along +x.
    const e = spawn(world, .{ .x = -10, .y = 0, .z = 0 }, std.math.pi / 2.0);
    ecs.get_mut(world, e, Intent).?.walk = .{ 0, 1 };
    for (0..60) |_| _ = ecs.progress(world, step_dt);
    const at = ecs.get(world, e, Position).?.at;
    try testing.expectApproxEqAbs(-10 + walk_speed, at.x, 1e-3);
    try testing.expectApproxEqAbs(0, at.z, 1e-3);
    const prev = ecs.get(world, e, Previous).?.at;
    try testing.expectApproxEqAbs(walk_speed * step_dt, at.x - prev.x, 1e-4);
}

test "a step up that's too steep stops the player; the eye stays level" {
    const s: Step = .{ .step = 1 }; // 1 m in one sample: far steeper than max_climb
    const g = s.ground();
    const world = testWorld(&g);
    defer _ = ecs.fini(world);
    const e = spawn(world, .{ .x = 0, .y = 0, .z = 0 }, std.math.pi / 2.0);
    ecs.get_mut(world, e, Intent).?.walk = .{ 0, 1 };
    for (0..60) |_| _ = ecs.progress(world, step_dt);
    const at = ecs.get(world, e, Position).?.at;
    try testing.expect(at.x < 1);
    try testing.expectEqual(0, at.y);
    try testing.expectApproxEqAbs(eye_height, ecs.get(world, e, Eye).?.y, 1e-5);
}

test "dropping down a step is allowed; the eye follows smoothly" {
    const s: Step = .{ .step = -1 };
    const g = s.ground();
    const world = testWorld(&g);
    defer _ = ecs.fini(world);
    const e = spawn(world, .{ .x = 0.99, .y = 0, .z = 0 }, std.math.pi / 2.0);
    ecs.get_mut(world, e, Intent).?.walk = .{ 0, 1 };
    _ = ecs.progress(world, step_dt);
    try testing.expectEqual(-1, ecs.get(world, e, Position).?.at.y);
    const eye1 = ecs.get(world, e, Eye).?.y;
    try testing.expect(eye1 < eye_height and eye1 > eye_height - 1); // part way down
    for (0..120) |_| _ = ecs.progress(world, step_dt);
    try testing.expectApproxEqAbs(eye_height - 1, ecs.get(world, e, Eye).?.y, 1e-3);
}

test "look: delta applied once, rate per second, pitch clamped" {
    const s: Step = .{ .step = 0 };
    const g = s.ground();
    const world = testWorld(&g);
    defer _ = ecs.fini(world);
    const e = spawn(world, .{ .x = -10, .y = 0, .z = 0 }, 0);
    ecs.get_mut(world, e, Intent).?.look_delta = .{ 0.5, 10 };
    for (0..3) |_| _ = ecs.progress(world, step_dt);
    var look = ecs.get(world, e, Look).?.*;
    try testing.expectApproxEqAbs(0.5, look.yaw, 1e-6);
    try testing.expectEqual(motion.max_pitch, look.pitch);
    ecs.get_mut(world, e, Intent).?.look_rate = .{ 1, 0 };
    for (0..60) |_| _ = ecs.progress(world, step_dt);
    look = ecs.get(world, e, Look).?.*;
    try testing.expectApproxEqAbs(1.5, look.yaw, 1e-3);
}

test "no ground ahead: the player stays put" {
    const Edge = struct {
        pub fn heightAt(_: *const @This(), x: f32, _: f32) ?f32 {
            return if (x < 0) 0 else null;
        }
    };
    const g: core.ground.Ground = .of(Edge, &.{});
    const world = testWorld(&g);
    defer _ = ecs.fini(world);
    const e = spawn(world, .{ .x = -0.01, .y = 0, .z = 0 }, std.math.pi / 2.0);
    ecs.get_mut(world, e, Intent).?.walk = .{ 0, 1 };
    for (0..10) |_| _ = ecs.progress(world, step_dt);
    try testing.expectEqual(-0.01, ecs.get(world, e, Position).?.at.x);
}

test "view interpolates the eye between steps and looks along Look" {
    const s: Step = .{ .step = 0 };
    const g = s.ground();
    const world = testWorld(&g);
    defer _ = ecs.fini(world);
    const e = spawn(world, .{ .x = -10, .y = 0, .z = 0 }, std.math.pi / 2.0);
    ecs.get_mut(world, e, Intent).?.walk = .{ 0, 1 };
    _ = ecs.progress(world, step_dt);
    const half = view(world, e, 0.5);
    try testing.expectApproxEqAbs(-10 + walk_speed * step_dt / 2, half.eye.x, 1e-5);
    try testing.expectApproxEqAbs(eye_height, half.eye.y, 1e-5);
    try testing.expectApproxEqAbs(1, half.dir.x, 1e-6);
    try testing.expectApproxEqAbs(-10 + walk_speed * step_dt, view(world, e, 1).eye.x, 1e-5);
}

test "view shows look input that no step has applied yet" {
    const s: Step = .{ .step = 0 };
    const g = s.ground();
    const world = testWorld(&g);
    defer _ = ecs.fini(world);
    const e = spawn(world, .{ .x = 0, .y = 0, .z = 0 }, 0);
    ecs.get_mut(world, e, Intent).?.look_delta = .{ std.math.pi / 2.0, 0 };
    try testing.expectApproxEqAbs(1, view(world, e, 0).dir.x, 1e-6);
    _ = ecs.progress(world, step_dt); // applied once, not twice
    try testing.expectApproxEqAbs(1, view(world, e, 0).dir.x, 1e-6);
}

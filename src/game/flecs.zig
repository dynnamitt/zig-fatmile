//! zflecs helpers that work around its bindings. Use these instead of
//! `ecs.set`, `ecs.set_pair`, `ecs.set_id` and `ecs.ADD_SYSTEM*`.
const ecs = @import("zflecs");

// zflecs declares ecs_set_id as returning entity_t, but flecs 4.1 returns void.
// Native ABIs ignore the bogus return value; on wasm, wasm-ld replaces the call
// with a trap. So declare it correctly and avoid ecs.set.
extern fn ecs_set_id(world: *ecs.world_t, entity: ecs.entity_t, component: ecs.id_t, size: usize, ptr: ?*const anyopaque) void;

/// Sets component `T` on `entity` to `val`.
pub fn set(world: *ecs.world_t, entity: ecs.entity_t, comptime T: type, val: T) void {
    ecs_set_id(world, entity, ecs.id(T), @sizeOf(T), &val);
}

/// `set` for the pair `(T, target)`, with `T`'s data.
pub fn setPair(world: *ecs.world_t, entity: ecs.entity_t, comptime T: type, target: ecs.entity_t, val: T) void {
    ecs_set_id(world, entity, ecs.pair(ecs.id(T), target), @sizeOf(T), &val);
}

pub const SystemOptions = struct {
    /// Query terms after the ones `f`'s parameters give; read them with `ecs.field`.
    terms: []const ecs.term_t = &.{},
    /// Shared data for the system, read back as `it.ctx`. Workers read it
    /// concurrently, so it must not change while `ecs.progress` runs.
    ctx: ?*anyopaque = null,
};

/// zflecs' `ADD_SYSTEM_WITH_FILTERS`, plus `multi_threaded` (which it can't
/// set) and a context pointer: every system may split across
/// `ecs.set_threads` workers, so it must write only the entities it iterates
/// and make structural changes through `it.world`.
pub fn addSystem(world: *ecs.world_t, name: [*:0]const u8, phase: ecs.entity_t, comptime f: anytype, opts: SystemOptions) void {
    var desc = ecs.SYSTEM_DESC_WITH_FILTERS(f, opts.terms);
    desc.phase = phase;
    desc.multi_threaded = true;
    desc.ctx = opts.ctx;
    _ = ecs.SYSTEM(world, name, &desc);
}

const std = @import("std");

const Counter = struct { n: u32 };
const Tally = struct { n: u32 };

fn bump(counters: []Counter) void {
    for (counters) |*c| c.n += 1;
}

test "set and setPair store the value" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    ecs.COMPONENT(world, Counter);
    ecs.COMPONENT(world, Tally);
    const e = ecs.new_id(world);
    const target = ecs.new_id(world);
    set(world, e, Counter, .{ .n = 3 });
    setPair(world, e, Tally, target, .{ .n = 5 });
    try std.testing.expectEqual(@as(u32, 3), ecs.get(world, e, Counter).?.n);
    try std.testing.expectEqual(@as(u32, 5), ecs.get_pair(world, e, ecs.id(Tally), target, Tally).?.n);
}

test "addSystem runs once per progress in its phase" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    ecs.COMPONENT(world, Counter);
    addSystem(world, "bump", ecs.OnUpdate, bump, .{});
    const e = ecs.new_id(world);
    set(world, e, Counter, .{ .n = 0 });
    for (0..3) |_| _ = ecs.progress(world, 1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 3), ecs.get(world, e, Counter).?.n);
}

fn bumpBy(it: *ecs.iter_t, counters: []Counter) void {
    const by: *const u32 = @ptrCast(@alignCast(it.ctx.?));
    for (counters) |*c| c.n += by.*;
}

test "addSystem passes ctx through to the system" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    ecs.COMPONENT(world, Counter);
    var by: u32 = 7;
    addSystem(world, "bump_by", ecs.OnUpdate, bumpBy, .{ .ctx = &by });
    const e = ecs.new_id(world);
    set(world, e, Counter, .{ .n = 0 });
    _ = ecs.progress(world, 1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 7), ecs.get(world, e, Counter).?.n);
}

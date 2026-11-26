//! Entry point: owns the window and the frame loop, and wires `core`, `game`
//! and the renderer together. Game logic belongs in `game`, drawing in
//! `render/`, platform shims in `platform/`. Native and web run the same
//! code; only the loop driver below differs.
const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const ecs = @import("zflecs");
const core = @import("core");
const game = @import("game");
const config = @import("config");
const hud = @import("render/hud.zig");
const scene = @import("render/scene.zig");
const TerrainStream = @import("TerrainStream.zig");

// Starting size. The window is resizable on both platforms: natively you
// drag or maximize it; on web raylib sizes the canvas to the browser
// viewport (window.innerWidth/innerHeight) and follows its resizes.
const width = 800;
const height = 450;
// emscripten_set_main_loop args: fps 0 = requestAnimationFrame; nonzero
// simulate_infinite_loop = never return from main.
const web_loop_fps = 0;
const web_simulate_infinite_loop = 1;

// Input tuning.
const mouse_sensitivity = 0.0025; // rad per pixel
const turn_rate = 2.2; // rad/s, arrows and right stick at full tilt
const stick_deadzone = 0.15;
// Debug camera lift (E up, Q down, never below the eye): climb speed in m/s
// is lift_base_rate + lift_gain × the current lift, so it speeds up with height.
const lift_base_rate = 20;
const lift_gain = 0.5;

/// Root `os` override, so std.heap.page_allocator works on emscripten.
pub const os = if (builtin.os.tag == .emscripten) @import("platform/emscripten.zig").os else struct {};

/// Globals, not locals in main: on web, emscripten_set_main_loop unwinds
/// main's stack and calls frame() later.
var world: *ecs.world_t = undefined;
var player: ecs.entity_t = undefined;
var stream: TerrainStream = undefined;
var ground: core.ground.Ground = undefined;
var clock: core.FixedClock = .{};
/// Walk forward without holding anything: R toggles it (web: the page's
/// auto-walk button sends R), so touchscreens can travel.
var auto_walk = false;
/// A touch was down last frame too, so this frame's delta is a drag, not
/// the jump to where the finger landed.
var was_touching = false;
var stats: core.FrameStats = .{};
/// Debug: metres the camera floats above the player's eye. No upper limit.
var lift: f32 = 0;

pub fn main() !void {
    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(width, height, "zig-fatmile");
    defer rl.closeWindow();

    stream = try .init(std.heap.c_allocator);
    defer stream.deinit();
    ground = stream.terrain.asGround();

    // Everything round the spawn point loads before the first frame, so the
    // player starts on the ground.
    stream.update(0, 0, std.math.maxInt(usize));
    const spawn_y = stream.terrain.heightAt(0, 0) orelse return error.NoGroundAtSpawn;

    world = ecs.init();
    defer _ = ecs.fini(world);
    game.register(world, &ground);
    if (config.threads > 0) ecs.set_threads(world, config.threads); // -Dthreads, native only
    player = game.player.spawn(world, .{ .x = 0, .y = spawn_y, .z = 0 }, 0);

    if (builtin.os.tag == .emscripten) {
        // raylib's web pacing (WindowShouldClose's emscripten_sleep, SetTargetFPS's
        // WaitTime) isn't vsync-aligned and needs Asyncify. Never returns, so
        // the defers above don't run.
        std.os.emscripten.emscripten_set_main_loop(frame, web_loop_fps, web_simulate_infinite_loop);
    } else {
        rl.setTargetFPS(60);
        while (!rl.windowShouldClose()) frame();
    }
}

fn frame() callconv(.c) void {
    const work_start = rl.getTime();
    readInput(ecs.get_mut(world, player, game.player.Intent).?);
    // Fixed steps, never raylib's raw dt: one long frame would otherwise
    // apply a huge step, and dt=0 (first frame) makes flecs measure its own clock.
    for (0..clock.advance(rl.getFrameTime())) |_| _ = ecs.progress(world, core.FixedClock.step_dt);
    // Between steps, never during one: systems read the terrain.
    const at = ecs.get(world, player, game.player.Position).?.at;
    stream.update(at.x, at.z, TerrainStream.loads_per_frame);
    lift = @max(0, lift + axis(.e, .q) * (lift_base_rate + lift_gain * lift) * rl.getFrameTime());

    rl.beginDrawing();
    defer rl.endDrawing();
    rl.clearBackground(rl.getColor(core.palette.background));
    var view = game.player.view(world, player, clock.alpha());
    view.eye.y += lift;
    const draws = scene.draw(scene.camera(view), stream.pieces.items, stream.material);

    // CPU work = ECS steps + chunk loads + issuing draw calls, up to here.
    // Flush raylib's last draw batch first so it counts. GPU time isn't
    // measured (GL runs asynchronously, so it shows up at present); the
    // present (buffer swap, vsync and setTargetFPS waits) is idle time and
    // stays out. On web performance.now() is coarsened (~0.1 ms), so read
    // the mean, not one frame.
    rl.gl.rlDrawRenderBatchActive();
    stats.add(rl.getFrameTime(), @floatCast(rl.getTime() - work_start));
    hud.drawStats(stats, stream.loaded.len, draws, auto_walk, lift);
    hud.drawHint();
}

/// Mouse, touch, keyboard and gamepad 0 → the player's intent. Mouse look is
/// drag-to-look (left button held), with no pointer lock: raylib's web
/// backend can't report lock state, and a lock the browser drops on Escape
/// would leave the view spinning with a free mouse. Dragging reads the same
/// mouse delta on both platforms.
fn readInput(intent: *game.player.Intent) void {
    if (rl.isKeyPressed(.r)) auto_walk = !auto_walk;

    // A one-finger drag looks too: raylib moves the mouse position with it.
    const touching = rl.getTouchPointCount() == 1;
    defer was_touching = touching;
    if (rl.isMouseButtonDown(.left) or (touching and was_touching)) {
        const d = rl.getMouseDelta();
        intent.look_delta[0] -= d.x * mouse_sensitivity;
        intent.look_delta[1] -= d.y * mouse_sensitivity;
    }

    var walk: [2]f32 = .{ axis(.d, .a), axis(.w, .s) };
    var turn: [2]f32 = .{ axis(.left, .right), axis(.up, .down) };
    if (rl.isGamepadAvailable(0)) {
        walk[0] += stick(.left_x);
        walk[1] -= stick(.left_y); // stick up is negative
        turn[0] -= stick(.right_x);
        turn[1] -= stick(.right_y);
    }
    if (auto_walk) walk[1] += 1; // capped to full speed in core.motion
    intent.walk = walk;
    intent.look_rate = .{ turn[0] * turn_rate, turn[1] * turn_rate };
}

/// 1 while `pos` is held, -1 while `neg` is, 0 for both or neither.
fn axis(pos: rl.KeyboardKey, neg: rl.KeyboardKey) f32 {
    return @as(f32, @floatFromInt(@intFromBool(rl.isKeyDown(pos)))) - @as(f32, @floatFromInt(@intFromBool(rl.isKeyDown(neg))));
}

fn stick(a: rl.GamepadAxis) f32 {
    const v = rl.getGamepadAxisMovement(0, a);
    return if (@abs(v) < stick_deadzone) 0 else v;
}

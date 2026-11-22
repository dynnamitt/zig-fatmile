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

/// Root `os` override, so std.heap.page_allocator works on emscripten.
pub const os = if (builtin.os.tag == .emscripten) @import("platform/emscripten.zig").os else struct {};

/// Globals, not locals in main: on web, emscripten_set_main_loop unwinds
/// main's stack and calls frame() later.
var world: *ecs.world_t = undefined;
var player: ecs.entity_t = undefined;
var stream: TerrainStream = undefined;
var ground: core.ground.Ground = undefined;
var clock: core.FixedClock = .{};
var stats: core.FrameStats = .{};

pub fn main() !void {
    rl.initWindow(width, height, "zig-fatmile");
    defer rl.closeWindow();
    scene.init();

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

    rl.beginDrawing();
    defer rl.endDrawing();
    rl.clearBackground(rl.getColor(core.palette.background));
    scene.draw(scene.camera(game.player.view(world, player, clock.alpha())), stream.meshes(), stream.material);

    // CPU work = ECS steps + chunk loads + issuing draw calls, up to here.
    // Flush raylib's last draw batch first so it counts. GPU time isn't
    // measured (GL runs asynchronously, so it shows up at present); the
    // present (buffer swap, vsync and setTargetFPS waits) is idle time and
    // stays out. On web performance.now() is coarsened (~0.1 ms), so read
    // the mean, not one frame.
    rl.gl.rlDrawRenderBatchActive();
    stats.add(rl.getFrameTime(), @floatCast(rl.getTime() - work_start));
    hud.drawStats(stats, stream.loaded.len);
    hud.drawHint();
}

/// Mouse, keyboard and gamepad 0 → the player's intent. Mouse look needs the
/// cursor captured: a click captures it (on web the browser's pointer lock
/// needs that click too), Escape releases it on web.
fn readInput(intent: *game.player.Intent) void {
    if (rl.isMouseButtonPressed(.left)) rl.disableCursor();
    if (rl.isCursorHidden()) {
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

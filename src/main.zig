//! Entry point: owns the window and the frame loop, and wires `core`, `game`
//! and the renderer together. Game logic belongs in `game`, drawing in
//! `render/`, platform shims in `platform/`.
const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const ecs = @import("zflecs");
const core = @import("core");
const game = @import("game");
const config = @import("config");
const hud = @import("render/hud.zig");
const scene = @import("render/scene.zig");

const width = 800;
const height = 450;
// emscripten_set_main_loop args: fps 0 = requestAnimationFrame; nonzero
// simulate_infinite_loop = never return from main.
const web_loop_fps = 0;
const web_simulate_infinite_loop = 1;

/// Root `os` override, so std.heap.page_allocator works on emscripten.
pub const os = if (builtin.os.tag == .emscripten) @import("platform/emscripten.zig").os else struct {};

/// Globals, not locals in main: on web, emscripten_set_main_loop unwinds
/// main's stack and calls frame() later.
var world: *ecs.world_t = undefined;
var clock: core.FixedClock = .{};
var stats: core.FrameStats = .{};

pub fn main() !void {
    rl.initWindow(width, height, "zig-fatmile");
    defer rl.closeWindow();

    world = ecs.init();
    defer _ = ecs.fini(world);
    game.register(world);
    if (config.threads > 0) ecs.set_threads(world, config.threads); // -Dthreads, native only

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
    // Fixed steps, never raylib's raw dt: one long frame would otherwise
    // apply a huge step, and dt=0 (first frame) makes flecs measure its own clock.
    for (0..clock.advance(rl.getFrameTime())) |_| _ = ecs.progress(world, core.FixedClock.step_dt);

    rl.beginDrawing();
    defer rl.endDrawing();
    rl.clearBackground(rl.getColor(core.palette.background));
    scene.draw(scene.camera);

    // CPU work = sim steps + issuing draw calls, up to here. Flush raylib's
    // last draw batch first so it counts. GPU time isn't measured (GL runs
    // asynchronously, so it shows up at present); the present (buffer swap,
    // vsync and setTargetFPS waits) is idle time and stays out. On web
    // performance.now() is coarsened (~0.1 ms), so read the mean, not one frame.
    rlDrawRenderBatchActive();
    stats.add(rl.getFrameTime(), @floatCast(rl.getTime() - work_start));
    hud.drawStats(stats);
}

// rlgl, part of the raylib library; raylib-zig doesn't export it as a module.
extern fn rlDrawRenderBatchActive() void;

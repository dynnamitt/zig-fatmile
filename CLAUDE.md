# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`zig-fatmile` — Zig scaffold combining **Raylib** (window + rendering, via `raylib-zig`) and **Flecs ECS** (via `zflecs`). Builds natively and for the browser (`wasm32-emscripten`).

**Direction** (issue #1, "a world"): this scaffold grows into a low-poly first-person 3D game on hex terrain. Ground meshes come from the hex layout of the sibling repo `dynnamitt/apicult-desigual-rs`: noise heights, gap quads between hexes, thin black partition lines. A script precomputes one large mesh offline and stores it as chunks that load on demand (no procedural generation at runtime in the first iteration). The player walks at head height with a wobbling camera (gamepad + mouse), cannot climb steep slopes but can always slide down, and has a shovel that lowers the hex under the crosshair (found by raycast). Scenery is Norse pine and oversized mushrooms on ground that is about 60% open, plus walkable rock clusters, in one desert sci-fi palette. An axe and bikes come later; the goal of the game is to find and evolve bikes. Big refinements go into a fork first. Until the first world iteration lands, the app draws a placeholder ground grid from head height.

## Toolchain

**Zig 0.17.x** (`minimum_zig_version = "0.17.0"`; CI pins 0.17.1). Both dependencies require 0.17. The 0.17 API differs from older tutorials: modules come from `b.createModule` + `exe_mod.linkLibrary(...)`; run args use `run_cmd.addPassthruArgs()` (there is no `b.args`); `zig init`'s `main` takes `std.process.Init`.

Agent skills are not committed: `skills-lock.json` pins them and `npx skills experimental_install -a claude-code` restores them (gitignored, under `.agents/` and `.claude/skills/`). The tracked `zig-ray-flecs` skill checks which skills and ZLS (`zig-lsp` plugin) are missing and how to install them.

## Commands

```sh
zig build                    # compile → zig-out/bin/zig-fatmile
zig build run                # compile and launch
zig build run -Dthreads=8    # Flecs worker threads (native only; default 0)
zig build test               # headless unit tests (core + game modules); single test: zig build test -Dtest-filter="<name>"
zig fmt --check build.zig build.zig.zon src   # formatting check, as CI runs it
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall   # web → zig-out/web/index.{html,js,wasm}
zig build run -Dtarget=wasm32-emscripten                       # web build + serve with emrun
```

The web build installs the Emscripten SDK on first use, into `zig-pkg/<emsdk hash>/` via raylib's "Activate EMSDK" step. That needs network access to github.com and storage.googleapis.com, and no system emsdk or `EMSDK` variable.

On Linux, raylib's GLFW backend needs X11/GL **dev headers** (`libx11-dev libxcursor-dev libxrandr-dev libxinerama-dev libxi-dev libgl-dev`). `zig build test` does not link raylib, so it works without them.

CI (`.github/workflows/ci.yml`) runs on pull requests (and manually via workflow_dispatch). Job `build-test` runs fmt check → `zig build test` → `zig build`. Job `web` runs the emscripten build and uploads `zig-out/web` as the `web` artifact. `.github/workflows/pages.yml` runs `zig build test` and then the same web build on every push to `main`, and deploys it (deploys are never cancelled midway) to GitHub Pages (`https://dynnamitt.github.io/zig-fatmile/`). That needs Settings → Pages → Source: **GitHub Actions**. Both workflows key the Emscripten SDK cache on the `emsdk` and `raylib_zig` hashes in `build.zig.zon`, which they read with `sed`, so keep those entries in their `.name = .{ ... .hash = "..." }` form.

## Dependencies

Pinned by commit + content hash in `build.zig.zon`: `raylib_zig` (raylib-zig org — moved from Not-Nik/raylib-zig) and `zflecs` (zig-gamedev, bundles flecs v4.1.x). Update with `zig fetch --save git+https://github.com/<repo>#<commit>`. Zig 0.17 unpacks packages into a **project-local `zig-pkg/`** directory (gitignored), not only the global cache.

Transitive deps: raylib-zig → raylib, raygui, emsdk; zflecs → translate-c → arocc (both on **codeberg.org**). Fetching needs github.com and codeberg.org.

## Architecture

Code is split into modules by dependency, each a directory under `src/` with a root file of the same name. `build.zig` wires them with `addImport`. A module only sees what it imports, so the boundaries are enforced:

| module | root | imports | holds |
|---|---|---|---|
| `core` | `src/core/core.zig` | nothing | engine-agnostic types and math: `FixedClock`, `FrameStats`, `palette` (0xRRGGBBAA `u32`s, repeated in `web/shell.html`) |
| `game` | `src/game/game.zig` | `zflecs`, `core` | ECS components, systems, `register(world)`; `game.flecs` has the zflecs workarounds (`set`, `setPair`, `addSystem`) |
| exe | `src/main.zig` | `raylib`, `zflecs`, `core`, `game`, `config` | window + frame loop; `render/` (raylib drawing: `scene.zig`, `hud.zig`) and `platform/` (`emscripten.zig`) are plain files of this module |

Rules for new code:
- **Never import raylib from `core` or `game`.** Both are test roots (`zig build test` runs them), so everything that doesn't draw stays testable with no window or GPU. Pure data and math (e.g. the terrain chunk reader for issue #1) go in `core`, or in a new raylib-free module if they grow. State that changes per step goes in `game` as components and systems.
- **Rendering only reads.** `render/` reads ECS data and `core` types. It doesn't change state, so the renderer can be swapped.
- **One concern per file.** A file that is one type is named after it (`FixedClock.zig`, with `@This()` fields at top level). A file of functions is lower-case (`hud.zig`). Tests sit at the bottom of the file they test. Each module root runs `testing.refAllDecls(@This())` so tests in the files it re-exports run too.
- A new module gets its own directory and root file, a `createModule` + `addImport` in `build.zig`, and, if it doesn't link raylib, a place in the test loop there.

Frame loop (`main.zig`): `frame()` keeps its state in file-level globals. Natively a `while (!rl.windowShouldClose())` loop calls `frame()`. On web, `std.os.emscripten.emscripten_set_main_loop(frame, 0, 1)` runs it on requestAnimationFrame, with no `setTargetFPS` and no `windowShouldClose` (their sleeps aren't vsync-aligned). `core.FixedClock` turns raylib's frame time into fixed `step_dt` (1/60 s) steps, at most `max_steps_per_frame` per frame (any further backlog is dropped). Each step calls `ecs.progress(world, step_dt)`. Then the frame draws: `scene.draw` (3D), then `hud.drawStats`. `clock.alpha()` is the weight to interpolate rendered state between the last two steps. Never pass raw frame time to `ecs.progress`: a long frame (hidden tab, dragged window) would apply one huge step, and dt=0 makes flecs measure its own clock. The top-right readout shows FPS and CPU work time: mean/max ms per frame over 0.5 s (`core.FrameStats`), measured up to just before present (after flushing raylib's last batch). GPU time, swap and vsync waits are left out; with `-Dthreads` it is wall time, not summed CPU. Worker threads only pay off for heavy ECS loads, so they are off by default and rejected for web (wasm threads need COOP/COEP headers, which Pages can't send).

### Web build (`addWebBuild` in build.zig)

- The app is compiled as a static library. raylib-zig's `emsdk.emccStep` then links it with raylib and flecs (it picks up libraries linked into the module graph) into `zig-out/web/index.*`, using `web/shell.html` as the page template.
- **zflecs has no emscripten support**, so `build.zig` adds the emsdk sysroot include path to the `flecs` artifact. It also makes that artifact depend on **raylib's existing** "Activate EMSDK" step, found with `findStep`. Do not call `emsdk.activateEmsdkStep(b)` a second time: two activations run `emsdk update/install` concurrently in the same directory.
- `emsdk` must stay in **our** `build.zig.zon` (lazy). raylib-zig's helpers resolve it from the root build.
- Asyncify is off (`.asyncify = false`): the browser drives `frame()` through `emscripten_set_main_loop`. That keeps the wasm about 40% smaller. Don't reintroduce blocking loops or `emscripten_sleep` on web.
- `main.zig` overrides `std.heap.page_allocator` on emscripten (`pub const os`, implemented in `src/platform/emscripten.zig`): zflecs allocates through it, and Zig's wasm default calls `memory.grow`, which fails on emscripten's fixed heap (`panic: OOM`). The replacement must return aligned, zero-filled memory (zflecs' `DebugAllocator` relies on zeroed pages).
- `STACK_SIZE` is raised from emscripten's 64 KiB (`web_stack_size` in build.zig); Debug web builds overflow the default.
- CI fails the web build on any `wasm-ld: function signature mismatch` warning: wasm-ld turns such calls into runtime traps.

### ECS conventions (zflecs)

Components are plain Zig structs registered with `ecs.COMPONENT`. Relationships with no data are registered with `ecs.TAG`. Systems are registered in `game.register` with `game.flecs.addSystem(world, name, phase, fn, extra_terms)`, where `fn` takes slices of components (optionally `*ecs.iter_t` first, e.g. for `it.delta_time`); read extra terms with `ecs.field` at named index constants. Systems must stay safe to split across workers: write only the iterated entities, and make structural changes through `it.world`. The zflecs README and its `src/tests.zig` (in `zig-pkg/zflecs-*/`) are the best API reference, except: **never use `ecs.set`, `ecs.set_pair` or `ecs.set_id`.** zflecs declares `ecs_set_id` with a wrong return type, so these trap on web; use `game.flecs.set` / `setPair`. Flecs is built whitelist-only (pipeline + system, plus log in Debug/ReleaseSafe for assert messages; `build.zig`): another add-on's API (timers, meta, JSON, REST, …) fails to link until you add its `toggle_<name>_addon = true` there, and log calls do nothing in ReleaseFast/Small.

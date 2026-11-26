# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`zig-fatmile` — Zig scaffold combining **Raylib** (window + rendering, via `raylib-zig`) and **Flecs ECS** (via `zflecs`). Builds natively and for the browser (`wasm32-emscripten`).

**Direction** (issue #1, "a world"): this scaffold grows into a low-poly first-person 3D game on hex terrain. Ground meshes come from the hex layout of the sibling repo `dynnamitt/apicult-desigual-rs`: noise heights, gap quads between hexes, thin black partition lines. Chunks are generated on demand while the game runs, by apicult's Rust code linked into the app (`apicult-ffi/`), so the world has no edge within any walkable distance. The player walks at head height with a wobbling camera (gamepad + mouse), cannot climb steep slopes but can always slide down, and has a shovel that lowers the hex under the crosshair (found by raycast). Scenery is Norse pine and oversized mushrooms on ground that is about 60% open, plus walkable rock clusters, in one desert sci-fi palette. An axe and bikes come later; the goal of the game is to find and evolve bikes. Big refinements go into a fork first. The first world iteration (issue #4) is in: you walk the generated chunks at head height, and chunks load and unload around you. Wobble, the shovel raycast, scenery and the sky come later.

## Process rules

- **Web and native run the same code.** No `if (emscripten)` paths in game, loading or rendering code. The only platform differences allowed are the frame-loop driver in `main.zig` and the allocator shim in `platform/`. If something can't work the same way on both, change the approach rather than branch.
- **The world is generated at runtime, never checked in.** apicult-desigual-rs builds each chunk through `apicult-ffi/`, the same Rust code on native and web. The only checked-in chunk is the test fixture `src/core/testdata/chunk_0_0.bin`: chunk 0,0 of apicult-ffi's `WORLD`, which repeats `src/core/world.zig` (change both together). apicult-ffi's `fixture_is_current` test fails when it goes stale.

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
cargo test --manifest-path apicult-ffi/Cargo.toml            # the Rust chunk wrapper's tests (CI runs them, and cargo fmt --check)
UPDATE_FIXTURE=1 cargo test --manifest-path apicult-ffi/Cargo.toml   # remake the test fixture after an apicult bump or a world change
```

`zig build` (native and web, not `zig build test`) runs cargo: it needs Rust, and for web `rustup target add wasm32-unknown-emscripten`. CI pins Rust 1.94.0. The cargo step (`addApicult` in build.zig) runs on every build, in cargo's own `apicult-ffi/target` (shared with `cargo test`), so cargo decides what to rebuild; the `.a` is copied into the zig cache for the link. Natively Rust's std also needs an unwinder: Zig's bundled libunwind (`linkSystemLibrary("unwind")`).

The web build installs the Emscripten SDK on first use, into `zig-pkg/<emsdk hash>/` via raylib's "Activate EMSDK" step. That needs network access to github.com and storage.googleapis.com, and no system emsdk or `EMSDK` variable.

On Linux, raylib's GLFW backend needs X11/GL **dev headers** (`libx11-dev libxcursor-dev libxrandr-dev libxinerama-dev libxi-dev libgl-dev`). `zig build test` does not link raylib, so it works without them.

CI (`.github/workflows/ci.yml`) runs on pull requests (and manually via workflow_dispatch). Job `build-test` runs fmt check (zig + cargo) → `cargo test` (apicult-ffi) → `zig build test` → `zig build`. Job `web` runs the emscripten build and uploads `zig-out/web` as the `web` artifact. `.github/workflows/pages.yml` runs `zig build test` and then the same web build on every push to `main`, and deploys it (deploys are never cancelled midway) to GitHub Pages (`https://dynnamitt.github.io/zig-fatmile/`). That needs Settings → Pages → Source: **GitHub Actions**. Both workflows key the Emscripten SDK cache on the `emsdk` and `raylib_zig` hashes in `build.zig.zon`, which they read with `sed`, so keep those entries in their `.name = .{ ... .hash = "..." }` form.

## Dependencies

Pinned by commit + content hash in `build.zig.zon`: `raylib_zig` (raylib-zig org — moved from Not-Nik/raylib-zig) and `zflecs` (zig-gamedev, bundles flecs v4.1.x). Update with `zig fetch --save git+https://github.com/<repo>#<commit>`. Zig 0.17 unpacks packages into a **project-local `zig-pkg/`** directory (gitignored), not only the global cache.

apicult-desigual-rs is a cargo git dependency of `apicult-ffi`, pinned by `rev` in `apicult-ffi/Cargo.toml`; the committed `Cargo.lock` also pins its noise/hexx/glam versions (apicult itself doesn't commit one). Bump with a new `rev`, then `cargo update --manifest-path apicult-ffi/Cargo.toml -p apicult-desigual`, and remake the test fixture.

Transitive deps: raylib-zig → raylib, raygui, emsdk; zflecs → translate-c → arocc (both on **codeberg.org**). Fetching needs github.com and codeberg.org.

## Architecture

Code is split into modules by dependency, each a directory under `src/` with a root file of the same name. `build.zig` wires them with `addImport`. A module only sees what it imports, so the boundaries are enforced:

| module | root | imports | holds |
|---|---|---|---|
| `core` | `src/core/core.zig` | nothing | engine-agnostic types and math: `FixedClock`, `FrameStats`, `palette` (0xRRGGBBAA `u32`s; the page colours are repeated in `web/shell.html`), `sky` (sun and moon directions, gradient shape, fog distances (`fog_end` asserted within `streaming.min_loaded_radius`), `hiddenByFog` for culling; the formulas live in the shaders), `Vec3`, `Hex` (hexx port), `Chunk` (chunk byte reader), `world` (every generator setting the game chooses: chunk radius, hex size, max height, seeds), `Terrain` (loaded chunks, ground height), `ground` (walk/slope rule), `streaming` (which chunks to load/free; `chunk_range` and the `min_loaded_radius` it guarantees, tested by sampling), `motion` (look/walk/smoothing), `ChunkMesh` (vertex arrays and bounds for a chunk or its drawn seams), `Aabb`, `Frustum` (planes from a view-projection matrix, box test) |
| `game` | `src/game/game.zig` | `zflecs`, `core` | ECS components, systems, `register(world, ground)`; `player.zig` (components, `steer` + `walk` systems, `spawn`); `game.flecs` has the zflecs workarounds (`set`, `setPair`, `addSystem`) |
| exe | `src/main.zig` | `raylib`, `zflecs`, `core`, `game`, `config` | window, frame loop, input → `Intent`; `TerrainStream.zig` (`ac_chunk` calls + GPU meshes as `core.streaming` plans; per chunk one mesh for its own tris and one mesh of the seams `Chunk.Seam.drawn` allows (apicult's consumer rule 1); the seam meshes and the draw list are rebuilt only when a chunk loads or unloads; a chunk `ac_chunk` can't build (null) lands in `broken`); `render/` (raylib drawing: `scene.zig`, `glsl.zig` (the per-API GLSL headers every shader goes through, uniform setters, `viewProj`), `Sky.zig` (full-screen sky quad at the far plane, drawn after the terrain so the depth test shades only uncovered pixels: gradient, sun, moon), `terrain.zig` (chunk meshes, culling of each chunk with its seams by `core.Frustum` from rlgl's matrices and by `core.sky.hiddenByFog`, + the terrain shader, which paints the partition lines along all four edges of every gap quad, from `ChunkMesh.rims` and `.bridges`, coloured by height from `palette.line` to `palette.line_high`, then fogged into `palette.sky_horizon` by distance; its GLSL header follows raylib's graphics API, `rlGetVersion`, never the build target), `hud.zig`) and `platform/` (`emscripten.zig`) are plain files of this module |

Rules for new code:
- **Never import raylib from `core` or `game`.** Both are test roots (`zig build test` runs them), so everything that doesn't draw stays testable with no window or GPU. Pure data and math (chunk reader, ground rule, which chunks are in range, mesh vertex arrays) go in `core`, or in a new raylib-free module if they grow. State that changes per step goes in `game` as components and systems. Test all of it, including the systems (step a test world with a stub `core.ground.Ground`).
- **Stay true to the generator.** `core.Hex` copies hexx 0.24's flat layout, rounding and `to_lower_res` constant for constant, and `core.Chunk` reads the bytes `apicult-ffi/src/lib.rs` writes (HXCK v3: the format apicult's old `hex-chunks` wrote, v1, minus its partition-line segments, plus the chunk's seams, grouped as apicult's `NoiseWorld::chunk` groups them; a Rust test checks that). Tests check both against a real generated chunk (`src/core/test_data.zig`, embedded via an anonymous import in `build.zig`); if an apicult bump changes the output or the hexx version, remake the fixture and change the port to match, not the tests.
- **Rendering only reads.** `render/` reads ECS data and `core` types. It doesn't change state, so the renderer can be swapped.
- **One concern per file.** A file that is one type is named after it (`FixedClock.zig`, with `@This()` fields at top level). A file of functions is lower-case (`hud.zig`). Exception: an `extern struct` can't be a file's own struct, so `core/vec.zig` declares `Vec3` inside. Tests sit at the bottom of the file they test. Each module root runs `testing.refAllDecls(@This())` so tests in the files it re-exports run too.
- A new module gets its own directory and root file, a `createModule` + `addImport` in `build.zig`, and, if it doesn't link raylib, a place in the test loop there.

Frame loop (`main.zig`): `frame()` keeps its state in file-level globals. Startup generates every chunk round the spawn point before the first frame. Natively a `while (!rl.windowShouldClose())` loop calls `frame()`. On web, `std.os.emscripten.emscripten_set_main_loop(frame, 0, 1)` runs it on requestAnimationFrame, with no `setTargetFPS` and no `windowShouldClose` (their sleeps aren't vsync-aligned). `core.FixedClock` turns raylib's frame time into fixed `step_dt` (1/60 s) steps, at most `max_steps_per_frame` per frame (any further backlog is dropped). Before the steps, input (mouse, WASD/arrows, gamepad 0) is written to the player's `Intent`. Each step calls `ecs.progress(world, step_dt)`. After the steps (never during one: the `walk` system reads the terrain), `TerrainStream.update` loads at most `loads_per_frame` chunks round the player and frees those past `chunk_range.keep`. Then the frame draws: `scene.draw` (3D: the terrain, then the sky behind it, through `game.player.view`: the eye interpolated by `clock.alpha()` between the last two steps, raised by the debug `lift` that E/Q change, with no upper limit; the far clip plane grows with the camera's height), then the HUD. Never pass raw frame time to `ecs.progress`: a long frame (hidden tab, dragged window) would apply one huge step, and dt=0 makes flecs measure its own clock. The top-right readout shows FPS and CPU work time: mean/max ms per frame over 0.5 s (`core.FrameStats`), measured up to just before present (after flushing raylib's last batch). GPU time, swap and vsync waits are left out; with `-Dthreads` it is wall time, not summed CPU. Worker threads only pay off for heavy ECS loads, so they are off by default and rejected for web (wasm threads need COOP/COEP headers, which Pages can't send).

### Web build (`addWebBuild` in build.zig)

- The app is compiled as a static library. raylib-zig's `emsdk.emccStep` then links it with raylib and flecs (it picks up libraries linked into the module graph) into `zig-out/web/index.*`, using `web/shell.html` as the page template.
- The window is resizable (`FLAG_WINDOW_RESIZABLE`, set in `main.zig` for both platforms). On web raylib then sizes the canvas drawing buffer to `window.innerWidth × innerHeight` and follows resizes; `web/shell.html` makes the canvas fixed full-viewport (`100vw × 100vh`, no border or scrollbars) so CSS pixels map 1:1 to that buffer, with the title and status as overlays. Draw with `rl.getScreenWidth/Height`, never the starting 800×450. HiDPI (`devicePixelRatio`) isn't handled.
- Input that only the page can offer goes through the game's own input, never a web-only path: the shell's **auto-walk** button sends a synthetic `R` keydown/keyup (the game's toggle; `keyCode` defined on the event because GLFW reads it, held 60 ms so a frame sees it). A one-finger drag looks like a mouse drag because raylib moves the mouse position with a single touch; the canvas has `touch-action: none` so drags don't pan the page.
- `apicult-ffi` is built by cargo for `wasm32-unknown-emscripten`, with emsdk's `emcc` as cargo's linker (`--config target.….linker`) after raylib's "Activate EMSDK" step. apicult-desigual is also a `cdylib`, which cargo links even as a dependency; that throwaway wasm has no `main`, hence `-C link-arg=--no-entry`. The `.a` is added to emccStep's Run step directly (`emccRun`) with `-fwasm-exceptions`: Rust's emscripten std uses wasm exception handling, and the link must match. The generator adds about 3 KB to `index.wasm`.
- **zflecs has no emscripten support**, so `build.zig` adds the emsdk sysroot include path to the `flecs` artifact. It also makes that artifact depend on **raylib's existing** "Activate EMSDK" step, found with `findStep`. Do not call `emsdk.activateEmsdkStep(b)` a second time: two activations run `emsdk update/install` concurrently in the same directory.
- `emsdk` must stay in **our** `build.zig.zon` (lazy). raylib-zig's helpers resolve it from the root build.
- Asyncify is off (`.asyncify = false`): the browser drives `frame()` through `emscripten_set_main_loop`. That keeps the wasm about 40% smaller. Don't reintroduce blocking loops or `emscripten_sleep` on web.
- `main.zig` overrides `std.heap.page_allocator` on emscripten (`pub const os`, implemented in `src/platform/emscripten.zig`): zflecs allocates through it, and Zig's wasm default calls `memory.grow`, which fails on emscripten's fixed heap (`panic: OOM`). The replacement must return aligned, zero-filled memory (zflecs' `DebugAllocator` relies on zeroed pages).
- `STACK_SIZE` is raised from emscripten's 64 KiB (`web_stack_size` in build.zig); Debug web builds overflow the default.
- CI fails the web build on any `wasm-ld: function signature mismatch` warning: wasm-ld turns such calls into runtime traps.

### ECS conventions (zflecs)

Components are plain Zig structs registered with `ecs.COMPONENT`. Relationships with no data are registered with `ecs.TAG`. Systems are registered in `game.register` with `game.flecs.addSystem(world, name, phase, fn, .{ .terms = …, .ctx = … })`, where `fn` takes slices of components (optionally `*ecs.iter_t` first, e.g. for `it.delta_time`); read extra terms with `ecs.field` at named index constants, and shared read-only data (like the ground) through `it.ctx`. Systems must stay safe to split across workers: write only the iterated entities, and make structural changes through `it.world`. The zflecs README and its `src/tests.zig` (in `zig-pkg/zflecs-*/`) are the best API reference, except: **never use `ecs.set`, `ecs.set_pair` or `ecs.set_id`.** zflecs declares `ecs_set_id` with a wrong return type, so these trap on web; use `game.flecs.set` / `setPair`. Flecs is built whitelist-only (pipeline + system, plus log in Debug/ReleaseSafe for assert messages; `build.zig`): another add-on's API (timers, meta, JSON, REST, …) fails to link until you add its `toggle_<name>_addon = true` there, and log calls do nothing in ReleaseFast/Small.

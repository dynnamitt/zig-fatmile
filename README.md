# zig-fatmile

[![Zig 0.17](https://img.shields.io/badge/Zig-0.17-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/download/)
[![WebGL](https://img.shields.io/badge/WebGL-live_demo-990000?logo=webgl&logoColor=white)](https://dynnamitt.github.io/zig-fatmile/)
[![WebAssembly](https://img.shields.io/badge/WebAssembly-emscripten-654FF0?logo=webassembly&logoColor=white)](https://emscripten.org/)

![rayzigflecs](tech-trio.svg)

Zig 0.17 scaffold: [raylib-zig](https://github.com/raylib-zig/raylib-zig) for window + rendering,
[zflecs](https://github.com/zig-gamedev/zflecs) for ECS. Both come in as Zig packages pinned in `build.zig.zon`.

```sh
zig build test   # headless unit tests (core maths + ECS systems)
zig build run    # launch (Linux needs X11/GL dev headers, see .github/workflows/ci.yml)
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall   # browser build → zig-out/web/
```

## Where this is going

A low-poly first-person hex-terrain world: walk, dig with a shovel, clear pines and giant mushrooms, and eventually ride bikes. The plan is in [issue #1](https://github.com/dynnamitt/zig-fatmile/issues/1).

Today you can walk the hex terrain: drag with the left mouse button (or one finger) to look, R or the page's **auto-walk** button to walk on without holding anything, WASD or the left stick to walk, arrows or the right stick to turn. For debugging, E raises the camera above you and Q lowers it again, with no upper limit; the speed grows with height. You can't climb slopes steeper than 45°, but you can always go down them. Chunks load around you as you walk; the readout in the corner counts them.

## Terrain

Each chunk is generated while you play, by [apicult-desigual-rs](https://github.com/dynnamitt/apicult-desigual-rs) through `apicult-ffi/`, a small Rust crate with a C ABI that `zig build` compiles with cargo and links into both the native and the web build. The world has no edge you could walk to. Its seeds and chunk size are in `src/core/world.zig`; the apicult version is the `rev` in `apicult-ffi/Cargo.toml`.

Building needs Rust (cargo), and for web also its target: `rustup target add wasm32-unknown-emscripten`.

## Updating deps

```sh
zig fetch --save git+https://github.com/raylib-zig/raylib-zig#<commit>
zig fetch --save git+https://github.com/zig-gamedev/zflecs#<commit>
# apicult: change `rev` in apicult-ffi/Cargo.toml, then
cargo update --manifest-path apicult-ffi/Cargo.toml -p apicult-desigual
```

Live demo, redeployed from `main` on every push: https://dynnamitt.github.io/zig-fatmile/

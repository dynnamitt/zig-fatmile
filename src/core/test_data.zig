//! Test fixture: chunk 0,0 of the world in `world.zig`, as apicult-ffi
//! writes it, embedded via an anonymous import that build.zig adds to
//! `core`. Tests only. apicult-ffi's `fixture_is_current` test fails when it
//! goes stale; `UPDATE_FIXTURE=1 cargo test` (in `apicult-ffi/`) remakes it.
const Hex = @import("Hex.zig");

pub const chunk_bytes = @embedFile("chunk_0_0");
pub const chunk_coord: Hex = .zero;

//! Test fixtures from the checked-in world (`terrain/`), embedded via
//! anonymous imports that build.zig adds to `core`. Tests only.
const Hex = @import("Hex.zig");

pub const chunk_bytes = @embedFile("terrain_chunk_0_0");
pub const manifest_json = @embedFile("terrain_manifest");

/// What `terrain/SOURCE` generated: `hex-chunks --radius 30 --chunk-radius 6`
/// with its default hex radius 4. The manifest test checks these.
pub const chunk_coord: Hex = .zero;
pub const chunk_radius: u32 = 6;
pub const hex_size: f32 = 4;

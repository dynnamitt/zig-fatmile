//! The world's generator settings: the one place they're set. All of them go
//! to apicult-ffi's `ac_chunk`; every other setting is apicult-desigual's
//! `HGridSettings::default()`. apicult-ffi's `WORLD` repeats them for its
//! tests and the fixture (`test_data.zig`): change both together.
pub const chunk_radius: u32 = 6;
pub const height_seed: u32 = 43;
pub const radius_seed: u32 = 137;
/// apicult's `nominal_hex_radius`: centre-to-corner size of a full cell, in metres.
pub const hex_size: f32 = 4;
/// Top of the height noise, in metres.
pub const max_height: f32 = 20;

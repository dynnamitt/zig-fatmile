//! C ABI over apicult-desigual's on-demand chunk generator.
//!
//! `ac_chunk` builds chunk `(q, r)` of an unbounded world and returns it as
//! HXCK v1 bytes, the format `src/core/Chunk.zig` reads (apicult wrote the
//! same layout as files up to e59947):
//!
//! | part | layout (little-endian) |
//! |---|---|
//! | header (40 B) | `"HXCK"`, `u32 1`, `i32 q`, `i32 r`, `u32 n_cells`, `u32 n_tris`, `u32 n_lines`, `u32 0`, `u64 hash` |
//! | cells | `n_cells × {i32 q, i32 r, f32 height, f32 radius, u32 first_tri, u8 n_quads, u8 n_junctions, u16 0}` |
//! | tris | `n_tris × 9 f32`: per cell 6 face tris, then 2 per owned gap quad, then junction tris |
//! | lines | `n_lines × 6 f32`: perimeter segments of the owned gap quads |
//!
//! `hash` is FNV-1a 64 over every byte after the header. The cells and tris
//! are what [`apicult_desigual::NoiseWorld`] puts in a chunk's owned stream.

use apicult_desigual::{HGridLayout, HGridSettings};
use glam::Vec3;
use hexx::{Hex, shapes};

const MAGIC: &[u8; 4] = b"HXCK";
const VERSION: u32 = 1;
const HEADER_LEN: usize = 40;
const CELL_LEN: usize = 24;
/// Header offsets of the fields written after the cells are known.
const N_CELLS_AT: usize = 16;
const HASH_AT: usize = 32;

/// The world settings zig-fatmile chooses; every other `HGridSettings` field
/// stays at apicult's default.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct World {
    /// Rings of cells per chunk.
    pub chunk_radius: u32,
    /// apicult's `nominal_hex_radius`: centre-to-corner size of a full cell, in metres.
    pub hex_size: f32,
    /// Top of the height noise, in metres.
    pub max_height: f32,
    pub height_seed: u32,
    pub radius_seed: u32,
}

/// zig-fatmile's world: the same values as `src/core/world.zig`, which passes
/// them to `ac_chunk`. The test fixture is chunk 0,0 of this world.
pub const WORLD: World = World {
    chunk_radius: 6,
    hex_size: 4.0,
    max_height: 20.0,
    height_seed: 43,
    radius_seed: 137,
};

/// Builds one chunk and encodes it.
///
/// @param world {World} — the world's settings, the same for every chunk.
/// @param coord {Hex} — the chunk's coordinate on the chunk lattice.
/// @returns {Vec<u8>} the chunk as HXCK v1 bytes (format in the module docs).
pub fn chunk_bytes(world: World, coord: Hex) -> Vec<u8> {
    let settings = HGridSettings {
        nominal_hex_radius: world.hex_size,
        max_height: world.max_height,
        height_noise_seed: world.height_seed,
        radius_noise_seed: world.radius_seed,
        ..HGridSettings::default()
    };
    let layout = HGridLayout::for_chunk(&settings, coord, world.chunk_radius);
    let mut tris: Vec<[Vec3; 3]> = Vec::new();
    let mut lines: Vec<[Vec3; 2]> = Vec::new();
    // Header with the cell count and hash still zero; both are patched below.
    let mut out: Vec<u8> = [
        MAGIC.as_slice(),
        &VERSION.to_le_bytes(),
        &coord.x.to_le_bytes(),
        &coord.y.to_le_bytes(),
        &[0; 24],
    ]
    .concat();
    for h in shapes::hexagon(layout.center(), world.chunk_radius) {
        let cell = layout.cell(&h).expect("own cell is in the chunk layout");
        let first = tris.len();
        let (faces, quads, junctions) = layout.owned_tris_into(h, false, &mut tris);
        assert_eq!(faces, 6, "own cells always own their face fan");
        // Owned gap quads follow the face tris as `[a,b,c], [a,c,d]` pairs.
        for pair in tris[first + faces..][..quads].chunks_exact(2) {
            let ([a, b, c], d) = (pair[0], pair[1][2]);
            lines.extend([[a, b], [b, c], [c, d], [d, a]]);
        }
        out.extend_from_slice(&h.x.to_le_bytes());
        out.extend_from_slice(&h.y.to_le_bytes());
        out.extend_from_slice(&cell.height.to_le_bytes());
        out.extend_from_slice(&cell.radius.to_le_bytes());
        out.extend_from_slice(&(first as u32).to_le_bytes());
        out.extend_from_slice(&[(quads / 2) as u8, junctions as u8, 0, 0]);
    }
    let n_cells = (out.len() - HEADER_LEN) / CELL_LEN;
    let counts = [n_cells, tris.len(), lines.len()].map(|n| (n as u32).to_le_bytes());
    out[N_CELLS_AT..][..12].copy_from_slice(&counts.concat());
    let floats = tris
        .iter()
        .flatten()
        .chain(lines.iter().flatten())
        .flat_map(|v| v.to_array());
    out.extend(floats.flat_map(f32::to_le_bytes));
    let hash = fnv1a64(&out[HEADER_LEN..]);
    out[HASH_AT..][..8].copy_from_slice(&hash.to_le_bytes());
    out
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |h, &b| {
        (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

/// Builds chunk `(q, r)` and returns its HXCK bytes; free them with `ac_free`.
///
/// @param chunk_radius {u32} — rings of cells per chunk.
/// @param hex_size {f32} — full cell size (centre to corner), in metres.
/// @param max_height {f32} — top of the height noise, in metres.
/// @param height_seed {u32} — height-noise seed, the same for every chunk of a world.
/// @param radius_seed {u32} — cell-radius-noise seed, likewise.
/// @param q {i32} — the chunk's coordinate on the chunk lattice.
/// @param r {i32} — likewise.
/// @param out_len {*mut usize} — receives the byte count.
/// @returns {*mut u8} the bytes, never null.
///
/// # Safety
/// `out_len` must be valid for a write.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)] // flat C ABI, no struct layout to keep in sync
pub unsafe extern "C" fn ac_chunk(
    chunk_radius: u32,
    hex_size: f32,
    max_height: f32,
    height_seed: u32,
    radius_seed: u32,
    q: i32,
    r: i32,
    out_len: *mut usize,
) -> *mut u8 {
    let world = World {
        chunk_radius,
        hex_size,
        max_height,
        height_seed,
        radius_seed,
    };
    let bytes = chunk_bytes(world, Hex::new(q, r)).into_boxed_slice();
    unsafe { *out_len = bytes.len() };
    Box::into_raw(bytes).cast()
}

/// Frees bytes from `ac_chunk`.
///
/// @param ptr {*mut u8} — what `ac_chunk` returned.
/// @param len {usize} — the byte count it wrote to `out_len`.
///
/// # Safety
/// `ptr` and `len` must come from one `ac_chunk` call, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ac_free(ptr: *mut u8, len: usize) {
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Zig tests' fixture (`src/core/test_data.zig`): chunk 0,0 of `WORLD`.
    const FIXTURE: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../src/core/testdata/chunk_0_0.bin"
    );

    #[test]
    fn header_counts_match_payload_anywhere() {
        // Near the origin, and far past the old checked-in world's edge.
        for coord in [Hex::new(-3, 2), Hex::new(400, -900)] {
            let b = chunk_bytes(WORLD, coord);
            let u32_at = |i: usize| u32::from_le_bytes(b[i..i + 4].try_into().unwrap()) as usize;
            assert_eq!(&b[0..4], MAGIC);
            assert_eq!(u32_at(N_CELLS_AT), 127); // 1 + 3·6·7 cells
            assert!(u32_at(24) > 0);
            assert_eq!(
                b.len(),
                HEADER_LEN + u32_at(16) * CELL_LEN + u32_at(20) * 36 + u32_at(24) * 24
            );
            assert_eq!(
                u64::from_le_bytes(b[HASH_AT..HASH_AT + 8].try_into().unwrap()),
                fnv1a64(&b[HEADER_LEN..])
            );
        }
    }

    /// Fails when apicult or `WORLD` changes the output; then
    /// `UPDATE_FIXTURE=1 cargo test` rewrites the fixture.
    #[test]
    fn fixture_is_current() {
        let bytes = chunk_bytes(WORLD, Hex::ZERO);
        if std::env::var_os("UPDATE_FIXTURE").is_some() {
            std::fs::write(FIXTURE, &bytes).unwrap();
        }
        assert!(
            std::fs::read(FIXTURE).unwrap() == bytes,
            "fixture is stale: UPDATE_FIXTURE=1 cargo test"
        );
    }

    #[test]
    fn fnv_known_vectors() {
        assert_eq!(fnv1a64(b""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(fnv1a64(b"a"), 0xaf63_dc4c_8601_ec8c);
    }
}

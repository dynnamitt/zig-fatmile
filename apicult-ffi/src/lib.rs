//! C ABI over apicult-desigual's on-demand chunk generator.
//!
//! `ac_chunk` builds chunk `(q, r)` of an unbounded world and returns it as
//! HXCK v3 bytes, the format `src/core/Chunk.zig` reads. v1 is what apicult
//! wrote as files up to e59947; v2 dropped its partition-line segments (the
//! terrain shader draws the lines); v3 adds the chunk's seams:
//!
//! | part | layout (little-endian) |
//! |---|---|
//! | header (40 B) | `"HXCK"`, `u32 3`, `i32 q`, `i32 r`, `u32 n_cells`, `u32 n_tris`, `u32 n_seams`, `u32 n_seam_tris`, `u64 hash` |
//! | cells | `n_cells × {i32 q, i32 r, f32 height, f32 radius, u32 first_tri, u8 n_quads, u8 n_junctions, u16 0}` |
//! | tris | `n_tris × 9 f32`: per cell 6 face tris (centre, rim corner, rim corner), then 2 per owned gap quad, then junction tris |
//! | seams | `n_seams × {i32 owner_q, i32 owner_r, i32 also_q, i32 also_r, u16 n_quad_tris, u16 n_junction_tris, u8 has_also, u8 0, u16 0}` |
//! | seam tris | `n_seam_tris × 9 f32`: per seam its gap-quad tris (pairs, as in the owned stream), then its junction tris |
//!
//! A seam is apicult's [`apicult_desigual::Seam`]: triangles a neighbour
//! chunk (`owner`) owns that touch this one, copied so this chunk can draw
//! them while the owner isn't loaded (rule: `Seam::drawn`). `also` is the
//! third chunk a corner junction touches. The grouping mirrors
//! `NoiseWorld::chunk`; a test checks it against that.
//!
//! `hash` is FNV-1a 64 over every byte after the header. The cells and tris
//! are what [`apicult_desigual::NoiseWorld`] puts in a chunk's owned stream.

use apicult_desigual::{HGridLayout, HGridSettings};
use glam::Vec3;
use hexx::{Hex, shapes};

const MAGIC: &[u8; 4] = b"HXCK";
const VERSION: u32 = 3;
const HEADER_LEN: usize = 40;
const CELL_LEN: usize = 24;
#[cfg(test)]
const SEAM_LEN: usize = 24;
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
/// @returns {Vec<u8>} the chunk as HXCK v3 bytes (format in the module docs).
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
        out.extend_from_slice(&h.x.to_le_bytes());
        out.extend_from_slice(&h.y.to_le_bytes());
        out.extend_from_slice(&cell.height.to_le_bytes());
        out.extend_from_slice(&cell.radius.to_le_bytes());
        out.extend_from_slice(&(first as u32).to_le_bytes());
        out.extend_from_slice(&[(quads / 2) as u8, junctions as u8, 0, 0]);
    }
    let n_cells = (out.len() - HEADER_LEN) / CELL_LEN;
    let seams = seams(&layout, coord, world.chunk_radius);
    let n_seam_tris: usize = seams
        .iter()
        .map(|s| s.quads.len() + s.junctions.len())
        .sum();
    let counts = [n_cells, tris.len(), seams.len(), n_seam_tris].map(|n| (n as u32).to_le_bytes());
    out[N_CELLS_AT..][..16].copy_from_slice(&counts.concat());
    out.extend(
        tris.iter()
            .flatten()
            .flat_map(|v| v.to_array())
            .flat_map(f32::to_le_bytes),
    );
    for s in &seams {
        let also = s.also.unwrap_or(Hex::ZERO);
        [s.owner.x, s.owner.y, also.x, also.y]
            .iter()
            .for_each(|v| out.extend_from_slice(&v.to_le_bytes()));
        out.extend_from_slice(&(s.quads.len() as u16).to_le_bytes());
        out.extend_from_slice(&(s.junctions.len() as u16).to_le_bytes());
        out.extend_from_slice(&[u8::from(s.also.is_some()), 0, 0, 0]);
    }
    let seam_tris = seams
        .iter()
        .flat_map(|s| s.quads.iter().chain(&s.junctions));
    out.extend(
        seam_tris
            .flatten()
            .flat_map(|v| v.to_array())
            .flat_map(f32::to_le_bytes),
    );
    let hash = fnv1a64(&out[HEADER_LEN..]);
    out[HASH_AT..][..8].copy_from_slice(&hash.to_le_bytes());
    out
}

/// One seam group, split into its gap-quad tris and its junction tris.
struct SeamGroup {
    owner: Hex,
    also: Option<Hex>,
    quads: Vec<[Vec3; 3]>,
    junctions: Vec<[Vec3; 3]>,
}

/// The seams of chunk `coord`, grouped exactly as apicult's
/// `NoiseWorld::chunk` groups them (src/chunk.rs at the pinned rev): every
/// tri a ring cell owns, keyed by `(owner, also)`, in first-seen order
/// walking the ring. Unlike apicult's, each group keeps quads and junctions
/// apart, so the quads stay in pairs for the line shader.
fn seams(layout: &HGridLayout, coord: Hex, r: u32) -> Vec<SeamGroup> {
    // A seam vertex is bit-for-bit a `vertex()` of ring cell `h` or a neighbour.
    let chunk_of = |h: Hex, v: &Vec3| {
        std::iter::once(h)
            .chain(h.all_neighbors())
            .find(|&n| (0..6).any(|i| layout.vertex(n, i) == Some(*v)))
            .expect("seam vertex is a corner of its ring cell or a neighbour")
            .to_lower_res(r)
    };
    let mut groups: Vec<SeamGroup> = Vec::new();
    for h in layout.center().ring(r + 1) {
        let owner = h.to_lower_res(r);
        let mut tris = Vec::new();
        let (faces, quads, _) = layout.owned_tris_into(h, false, &mut tris);
        assert_eq!(
            faces, 0,
            "ring cells are entangled: no face of their own here"
        );
        for (i, t) in tris.into_iter().enumerate() {
            let also = t
                .iter()
                .map(|v| chunk_of(h, v))
                .find(|&c| c != coord && c != owner);
            let at = match groups
                .iter()
                .position(|s| s.owner == owner && s.also == also)
            {
                Some(at) => at,
                None => {
                    groups.push(SeamGroup {
                        owner,
                        also,
                        quads: Vec::new(),
                        junctions: Vec::new(),
                    });
                    groups.len() - 1
                }
            };
            if i < quads {
                &mut groups[at].quads
            } else {
                &mut groups[at].junctions
            }
            .push(t);
        }
    }
    groups
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
            assert!(u32_at(24) > 0 && u32_at(28) > 0, "every chunk has seams");
            assert_eq!(
                b.len(),
                HEADER_LEN
                    + u32_at(16) * CELL_LEN
                    + u32_at(20) * 36
                    + u32_at(24) * SEAM_LEN
                    + u32_at(28) * 36
            );
            assert_eq!(
                u64::from_le_bytes(b[HASH_AT..HASH_AT + 8].try_into().unwrap()),
                fnv1a64(&b[HEADER_LEN..])
            );
        }
    }

    /// Our seam groups hold exactly the tris of apicult's own, per `(owner, also)`.
    #[test]
    fn seams_match_apicult() {
        use apicult_desigual::{ChunkSource, NoiseWorld};
        let settings = HGridSettings {
            nominal_hex_radius: WORLD.hex_size,
            max_height: WORLD.max_height,
            height_noise_seed: WORLD.height_seed,
            radius_noise_seed: WORLD.radius_seed,
            ..HGridSettings::default()
        };
        let source = NoiseWorld {
            settings: settings.clone(),
            chunk_radius: WORLD.chunk_radius,
        };
        let bits = |ts: &[[Vec3; 3]]| {
            let mut v: Vec<[u32; 9]> = ts
                .iter()
                .map(|t| std::array::from_fn(|i| t[i / 3].to_array()[i % 3].to_bits()))
                .collect();
            v.sort();
            v
        };
        for coord in [Hex::ZERO, Hex::new(-3, 2), Hex::new(7, -1)] {
            let layout = HGridLayout::for_chunk(&settings, coord, WORLD.chunk_radius);
            let ours = seams(&layout, coord, WORLD.chunk_radius);
            let theirs = source.chunk(coord).seams;
            assert_eq!(ours.len(), theirs.len());
            for (o, t) in ours.iter().zip(&theirs) {
                assert_eq!(
                    (o.owner, o.also),
                    (t.owner, t.also),
                    "same groups, same order"
                );
                assert_eq!(
                    bits(&[o.quads.clone(), o.junctions.clone()].concat()),
                    bits(&t.tris)
                );
                // Quads come whole, and only between two chunks.
                assert!(o.quads.len() % 2 == 0 && (o.quads.is_empty() || o.also.is_none()));
            }
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

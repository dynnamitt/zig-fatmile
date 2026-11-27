//! C ABI over apicult-desigual's chunk functions: no geometry or grouping
//! logic of its own (apicult-desigual-rs#38 rule 1). `ac_chunk` builds chunk
//! `(q, r)` from noise plus the caller's stored edits and copies apicult's
//! outputs, in apicult's order, into one HXCK v4 buffer that
//! `src/core/Chunk.zig` reads in place:
//!
//! | part | layout (little-endian) | from apicult |
//! |---|---|---|
//! | header (40 B) | `"HXCK"`, `u32 4`, `i32 q`, `i32 r`, `u32 n_cells`, `u32 n_tris`, `u32 n_ring`, `u32 n_seam_tris`, `u64 hash` | |
//! | cells | `n_cells × {i32 q, i32 r, f32 height, f32 radius}` | `own_cell_states` |
//! | tris | `n_tris × 9 f32`, 14 per cell: 6 face, 6 gap-quad (pairs), 2 junction | `own_tris` |
//! | ring | `n_ring × {u16 n_quad_tris, u16 n_junction_tris}` | `entangled_seam_counts` |
//! | seam keys | `n_seam_tris × {i32 owner_q, i32 owner_r, i32 also_q, i32 also_r}`; no `also` repeats the owner | `entangled_seam_keys` |
//! | seam tris | `n_seam_tris × 9 f32`: per ring cell its quad tris (pairs), then its junction tris | `entangled_seam_tris` |
//!
//! `hash` is FNV-1a 64 over every byte after the header: the format is read
//! in place, so it guards against a truncated or garbled buffer.

use apicult_desigual::{
    ChunkError, EntangledSeam, HGridLayout, HGridSettings, NoiseType, Override, entangled_seam_keys,
};
use glam::Vec3;
use hexx::Hex;

const MAGIC: &[u8; 4] = b"HXCK";
const VERSION: u32 = 4;
const HEADER_LEN: usize = 40;
#[cfg(test)]
const CELL_LEN: usize = 16;
#[cfg(test)]
const RING_LEN: usize = 4;
#[cfg(test)]
const KEY_LEN: usize = 16;
#[cfg(test)]
const TRI_LEN: usize = 36;
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

impl World {
    fn settings(self) -> HGridSettings {
        let mut g = HGridSettings {
            nominal_hex_radius: self.hex_size,
            max_height: self.max_height,
            ..HGridSettings::default()
        };
        g.height_noise.seed = self.height_seed;
        g.radius_noise.seed = self.radius_seed;
        g
    }
}

/// One stored edit, as the caller passes it: the final value of one channel
/// of cell `(q, r)` (apicult's `Override`, D13: absolute, not an offset).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AcEdit {
    pub q: i32,
    pub r: i32,
    /// `AC_HEIGHT` or `AC_SIZE`.
    pub channel: u32,
    pub value: f32,
}

pub const AC_HEIGHT: u32 = 0;
pub const AC_SIZE: u32 = 1;

/// Why `ac_chunk` returned null, as written to its `out_err`.
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AcError {
    None = 0,
    /// apicult's `ChunkError::OverrideOutsideChunk`.
    EditOutsideChunk = 1,
    /// apicult's `ChunkError::NonFiniteOverride`.
    NonFiniteEdit = 2,
    /// apicult's `ChunkError::TooFarFromOrigin`.
    TooFarFromOrigin = 3,
    /// An edit's `channel` is neither `AC_HEIGHT` nor `AC_SIZE`.
    BadChannel = 4,
    /// A count doesn't fit its field in the format.
    TooMany = 5,
}

impl From<ChunkError> for AcError {
    fn from(e: ChunkError) -> Self {
        match e {
            ChunkError::OverrideOutsideChunk(_) => Self::EditOutsideChunk,
            ChunkError::NonFiniteOverride(_) => Self::NonFiniteEdit,
            ChunkError::TooFarFromOrigin(_) => Self::TooFarFromOrigin,
        }
    }
}

fn overrides(edits: &[AcEdit]) -> Result<Vec<Override>, AcError> {
    edits
        .iter()
        .map(|e| {
            let channel = match e.channel {
                AC_HEIGHT => NoiseType::Height,
                AC_SIZE => NoiseType::Size,
                _ => return Err(AcError::BadChannel),
            };
            Ok((channel, Hex::new(e.q, e.r), e.value))
        })
        .collect()
}

fn fit<T: TryFrom<usize>>(n: usize) -> Result<T, AcError> {
    T::try_from(n).map_err(|_| AcError::TooMany)
}

fn put_tris(out: &mut Vec<u8>, tris: &[[Vec3; 3]]) {
    out.extend(
        tris.iter()
            .flatten()
            .flat_map(|v| v.to_array())
            .flat_map(f32::to_le_bytes),
    );
}

/// Builds one chunk and encodes it (format in the module docs).
///
/// @param world {World} — the world's settings, the same for every chunk.
/// @param coord {Hex} — the chunk's coordinate on the chunk lattice.
/// @param edits {&[AcEdit]} — the stored edits of the chunk's own cells and
///   its entangled ring.
/// @returns {Result<Vec<u8>, AcError>} the HXCK v4 bytes, or why not.
pub fn chunk_bytes(world: World, coord: Hex, edits: &[AcEdit]) -> Result<Vec<u8>, AcError> {
    let r = world.chunk_radius;
    let layout = HGridLayout::for_chunk(&world.settings(), coord, r, &overrides(edits)?)?;
    let cells = layout.own_cell_states();
    let tris = layout.own_tris();
    let ring = layout.entangled_seam_counts();
    let keys = entangled_seam_keys(coord, r)?;
    let seam_tris = layout.entangled_seam_tris();

    let counts = [cells.len(), tris.len(), ring.len(), seam_tris.len()];
    let mut out: Vec<u8> = [MAGIC.as_slice(), &VERSION.to_le_bytes()].concat();
    out.extend_from_slice(&coord.x.to_le_bytes());
    out.extend_from_slice(&coord.y.to_le_bytes());
    for n in counts {
        out.extend_from_slice(&fit::<u32>(n)?.to_le_bytes());
    }
    out.extend_from_slice(&[0; 8]); // hash, patched below
    for c in &cells {
        out.extend_from_slice(&c.hex.x.to_le_bytes());
        out.extend_from_slice(&c.hex.y.to_le_bytes());
        out.extend_from_slice(&c.height.to_le_bytes());
        out.extend_from_slice(&c.radius.to_le_bytes());
    }
    put_tris(&mut out, &tris);
    for &(quads, junctions) in &ring {
        out.extend_from_slice(&fit::<u16>(quads)?.to_le_bytes());
        out.extend_from_slice(&fit::<u16>(junctions)?.to_le_bytes());
    }
    for &EntangledSeam { owner, also } in &keys {
        let also = also.unwrap_or(owner);
        for v in [owner.x, owner.y, also.x, also.y] {
            out.extend_from_slice(&v.to_le_bytes());
        }
    }
    put_tris(&mut out, &seam_tris);
    let hash = fnv1a64(&out[HEADER_LEN..]);
    out[HASH_AT..][..8].copy_from_slice(&hash.to_le_bytes());
    Ok(out)
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |h, &b| {
        (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

/// Builds chunk `(q, r)` with the caller's stored edits and returns its HXCK
/// bytes; free them with `ac_free`.
///
/// @param chunk_radius {u32} — rings of cells per chunk.
/// @param hex_size {f32} — full cell size (centre to corner), in metres.
/// @param max_height {f32} — top of the height noise, in metres.
/// @param height_seed {u32} — height-noise seed, the same for every chunk of a world.
/// @param radius_seed {u32} — cell-radius-noise seed, likewise.
/// @param q {i32} — the chunk's coordinate on the chunk lattice.
/// @param r {i32} — likewise.
/// @param edits {*const AcEdit} — `n_edits` stored edits of the chunk's own
///   cells and its entangled ring; may be null when `n_edits` is 0.
/// @param n_edits {usize} — how many.
/// @param out_len {*mut usize} — receives the byte count (0 on failure).
/// @param out_err {*mut u32} — receives an `AcError` (0 on success).
/// @returns {*mut u8} the bytes, or null with `out_err` set; nothing to free then.
///
/// # Safety
/// `out_len` and `out_err` must be valid for a write; `edits` must point to
/// `n_edits` readable `AcEdit`s unless `n_edits` is 0.
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
    edits: *const AcEdit,
    n_edits: usize,
    out_len: *mut usize,
    out_err: *mut u32,
) -> *mut u8 {
    let world = World {
        chunk_radius,
        hex_size,
        max_height,
        height_seed,
        radius_seed,
    };
    let edits = if n_edits == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(edits, n_edits) }
    };
    match chunk_bytes(world, Hex::new(q, r), edits) {
        Ok(bytes) => {
            let bytes = bytes.into_boxed_slice();
            unsafe {
                *out_len = bytes.len();
                *out_err = AcError::None as u32;
            }
            Box::into_raw(bytes).cast()
        }
        Err(e) => {
            unsafe {
                *out_len = 0;
                *out_err = e as u32;
            }
            std::ptr::null_mut()
        }
    }
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
    /// The Zig port of `EntangledSeam::drawn` reads this copy of apicult's table.
    const DRAWN_TABLE: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../src/core/testdata/entangled_seam_drawn.tsv"
    );

    fn u32_at(b: &[u8], i: usize) -> usize {
        u32::from_le_bytes(b[i..i + 4].try_into().unwrap()) as usize
    }

    #[test]
    fn header_counts_match_payload_anywhere() {
        // Near the origin, and far past the old checked-in world's edge.
        for coord in [Hex::new(-3, 2), Hex::new(400, -900)] {
            let b = chunk_bytes(WORLD, coord, &[]).unwrap();
            assert_eq!(&b[0..4], MAGIC);
            let [cells, tris, ring, seam_tris] = [16, 20, 24, 28].map(|i| u32_at(&b, i));
            assert_eq!(cells, 127); // 1 + 3·6·7 cells
            assert_eq!(tris, 14 * cells);
            assert_eq!(ring, 6 * 7);
            assert!(seam_tris > 0, "every chunk has seams");
            let len = cells * CELL_LEN + tris * TRI_LEN + ring * RING_LEN;
            assert_eq!(b.len(), HEADER_LEN + len + seam_tris * (KEY_LEN + TRI_LEN));
            let hash = u64::from_le_bytes(b[HASH_AT..HASH_AT + 8].try_into().unwrap());
            assert_eq!(hash, fnv1a64(&b[HEADER_LEN..]));
        }
    }

    #[test]
    fn edits_reach_the_chunk_and_bad_ones_are_errors() {
        let (coord, hex) = (Hex::ZERO, Hex::new(1, -1));
        let edit = AcEdit {
            q: hex.x,
            r: hex.y,
            channel: AC_HEIGHT,
            value: 2.5,
        };
        let b = chunk_bytes(WORLD, coord, &[edit]).unwrap();
        let cells = &b[HEADER_LEN..HEADER_LEN + 127 * CELL_LEN];
        let found = cells.chunks(CELL_LEN).any(|c| {
            c[0..8] == [hex.x.to_le_bytes(), hex.y.to_le_bytes()].concat()
                && f32::from_le_bytes(c[8..12].try_into().unwrap()) == 2.5
        });
        assert!(found, "the edited height is in the cells");
        assert_ne!(b, chunk_bytes(WORLD, coord, &[]).unwrap());
        let bad = |e: AcEdit| chunk_bytes(WORLD, coord, &[e]).err();
        assert_eq!(
            bad(AcEdit { channel: 7, ..edit }),
            Some(AcError::BadChannel)
        );
        assert_eq!(
            bad(AcEdit {
                value: f32::NAN,
                ..edit
            }),
            Some(AcError::NonFiniteEdit)
        );
        assert_eq!(
            bad(AcEdit { q: 50, ..edit }),
            Some(AcError::EditOutsideChunk)
        );
        let far = chunk_bytes(WORLD, Hex::new(i32::MAX, 0), &[]).err();
        assert_eq!(far, Some(AcError::TooFarFromOrigin));
    }

    /// Fails when apicult or `WORLD` changes the output; then
    /// `UPDATE_FIXTURE=1 cargo test` rewrites the fixture (and the table copy).
    #[test]
    fn fixture_is_current() {
        let bytes = chunk_bytes(WORLD, Hex::ZERO, &[]).unwrap();
        if std::env::var_os("UPDATE_FIXTURE").is_some() {
            std::fs::write(FIXTURE, &bytes).unwrap();
        }
        assert!(
            std::fs::read(FIXTURE).unwrap() == bytes,
            "fixture is stale: UPDATE_FIXTURE=1 cargo test"
        );
    }

    #[test]
    fn drawn_table_is_current() {
        let table = apicult_desigual::ENTANGLED_SEAM_DRAWN_TABLE;
        if std::env::var_os("UPDATE_FIXTURE").is_some() {
            std::fs::write(DRAWN_TABLE, table).unwrap();
        }
        assert!(
            std::fs::read_to_string(DRAWN_TABLE).unwrap() == table,
            "seam draw table copy is stale: UPDATE_FIXTURE=1 cargo test"
        );
    }

    #[test]
    fn ac_chunk_round_trip() {
        let (mut len, mut err) = (0, 99);
        let w = WORLD;
        let c = Hex::new(2, -1).to_higher_res(w.chunk_radius); // the chunk's centre cell
        let edit = AcEdit {
            q: c.x,
            r: c.y,
            channel: AC_SIZE,
            value: 1.0,
        };
        let (rs, hs, mh) = (w.radius_seed, w.height_seed, w.max_height);
        let ptr = unsafe {
            ac_chunk(
                w.chunk_radius,
                w.hex_size,
                mh,
                hs,
                rs,
                2,
                -1,
                &edit,
                1,
                &mut len,
                &mut err,
            )
        };
        assert!(!ptr.is_null() && err == 0);
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
        unsafe { ac_free(ptr, len) };
        assert_eq!(bytes, chunk_bytes(WORLD, Hex::new(2, -1), &[edit]).unwrap());

        let bad = AcEdit { channel: 9, ..edit };
        let ptr = unsafe {
            ac_chunk(
                w.chunk_radius,
                w.hex_size,
                mh,
                hs,
                rs,
                2,
                -1,
                &bad,
                1,
                &mut len,
                &mut err,
            )
        };
        assert!(ptr.is_null() && len == 0 && err == AcError::BadChannel as u32);
        let none = std::ptr::null();
        let ptr = unsafe {
            ac_chunk(
                w.chunk_radius,
                w.hex_size,
                mh,
                hs,
                rs,
                0,
                0,
                none,
                0,
                &mut len,
                &mut err,
            )
        };
        assert!(!ptr.is_null() && err == 0);
        unsafe { ac_free(ptr, len) };
    }

    #[test]
    fn fnv_known_vectors() {
        assert_eq!(fnv1a64(b""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(fnv1a64(b"a"), 0xaf63_dc4c_8601_ec8c);
    }
}

// SPDX-License-Identifier: MPL-2.0

//! Detached signature container parsing.
//!
//! A detached signature file produced by `codesign -s ... --detached <file>` is
//! a `CSMAGIC_DETACHED_SIGNATURE` (`0xfade0cc1`) SuperBlob whose index entries
//! are keyed by CPU type rather than by the usual slot numbers. Each entry's
//! payload is a `CSMAGIC_EMBEDDED_SIGNATURE` (`0xfade0cc0`) blob that would
//! have been spliced into the Mach-O's `LC_CODE_SIGNATURE` if signing had
//! happened in place.
//!
//! There is also an entry with CPU type 0 that carries bundle-level resources
//! (CodeResources plist content, wrapped). We ignore that here since the
//! splicer only handles per-Mach-O signatures.

use anyhow::{anyhow, bail, Context as _, Result};

const CSMAGIC_DETACHED_SIGNATURE: u32 = 0xfade_0cc1;
const CSMAGIC_EMBEDDED_SIGNATURE: u32 = 0xfade_0cc0;

/// CPU type value used in a detached signature index entry for the
/// bundle-level CodeResources blob (not an actual CPU type).
const CPU_TYPE_BUNDLE_RESOURCES: u32 = 0;

/// Sentinel used to tag a bare `CSMAGIC_EMBEDDED_SIGNATURE` supplied as the
/// input. Such a blob is not keyed by CPU type and is usable for any
/// Mach-O.
pub const CPU_TYPE_UNQUALIFIED: u32 = u32::MAX;

/// One entry from a detached signature's top-level index.
#[derive(Debug, Clone)]
pub struct DetachedEntry<'a> {
    /// CPU type the entry is keyed by, or 0 for bundle resources.
    pub cpu_type: u32,
    /// Raw blob bytes at this entry's offset, typically a
    /// `CSMAGIC_EMBEDDED_SIGNATURE` SuperBlob.
    pub blob: &'a [u8],
}

/// Parse a detached-signature file produced by `codesign --detached`.
///
/// Accepts either a full `CSMAGIC_DETACHED_SIGNATURE` container or a bare
/// `CSMAGIC_EMBEDDED_SIGNATURE` blob (the latter is returned as a single
/// entry with `cpu_type = 0`).
pub fn parse_detached(data: &[u8]) -> Result<Vec<DetachedEntry<'_>>> {
    if data.len() < 12 {
        bail!("detached signature too short ({} bytes)", data.len());
    }

    let magic = read_u32_be(data, 0)?;

    match magic {
        CSMAGIC_EMBEDDED_SIGNATURE => {
            // Bare embedded signature; use it for any CPU type.
            Ok(vec![DetachedEntry {
                cpu_type: CPU_TYPE_UNQUALIFIED,
                blob: data,
            }])
        }
        CSMAGIC_DETACHED_SIGNATURE => parse_detached_container(data),
        other => Err(anyhow!(
            "unexpected magic 0x{other:08x} (want 0x{CSMAGIC_DETACHED_SIGNATURE:08x} or \
             0x{CSMAGIC_EMBEDDED_SIGNATURE:08x})"
        )),
    }
}

fn parse_detached_container(data: &[u8]) -> Result<Vec<DetachedEntry<'_>>> {
    let length = read_u32_be(data, 4)? as usize;
    if length > data.len() {
        bail!(
            "detached signature declares length {length} but file is only {} bytes",
            data.len()
        );
    }
    let count = read_u32_be(data, 8)? as usize;

    let index_start = 12usize;
    let index_end = index_start
        .checked_add(count.checked_mul(8).context("index size overflow")?)
        .context("index end overflow")?;
    if index_end > length {
        bail!("detached signature index extends past declared length");
    }

    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        let entry_off = index_start + i * 8;
        let cpu_type = read_u32_be(data, entry_off)?;
        let blob_off = read_u32_be(data, entry_off + 4)? as usize;

        if blob_off + 8 > length {
            bail!("detached signature entry {i} offset out of range");
        }
        let blob_len = read_u32_be(data, blob_off + 4)? as usize;
        if blob_off + blob_len > length {
            bail!("detached signature entry {i} blob exceeds file bounds");
        }

        out.push(DetachedEntry {
            cpu_type,
            blob: &data[blob_off..blob_off + blob_len],
        });
    }

    Ok(out)
}

/// Select the blob appropriate for a Mach-O with the given CPU type.
///
/// Prefers an exact CPU-type match, falls back to the single non-bundle
/// entry if the file is thin and the container has only one per-arch entry.
pub fn pick_for_cpu<'a>(entries: &'a [DetachedEntry<'a>], cpu_type: u32) -> Result<&'a [u8]> {
    let per_arch: Vec<_> = entries
        .iter()
        .filter(|e| e.cpu_type != CPU_TYPE_BUNDLE_RESOURCES)
        .collect();

    if let Some(exact) = per_arch.iter().find(|e| e.cpu_type == cpu_type) {
        return Ok(exact.blob);
    }

    if let Some(unq) = per_arch.iter().find(|e| e.cpu_type == CPU_TYPE_UNQUALIFIED) {
        return Ok(unq.blob);
    }

    if per_arch.len() == 1 {
        return Ok(per_arch[0].blob);
    }

    let available: Vec<String> = per_arch
        .iter()
        .map(|e| format!("0x{:08x}", e.cpu_type))
        .collect();
    bail!(
        "no detached signature entry for CPU type 0x{cpu_type:08x}; available: [{}]",
        available.join(", ")
    )
}

fn read_u32_be(data: &[u8], offset: usize) -> Result<u32> {
    let bytes: [u8; 4] = data
        .get(offset..offset + 4)
        .ok_or_else(|| anyhow!("read_u32_be out of range at offset {offset}"))?
        .try_into()
        .unwrap();
    Ok(u32::from_be_bytes(bytes))
}

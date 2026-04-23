// SPDX-License-Identifier: MPL-2.0

//! Splice precomputed Apple detached code signatures into unsigned Mach-O
//! binaries.
//!
//! The splicer accepts a Mach-O binary and a detached signature (produced by
//! `codesign -s <identity> --detached <out> <path>`) and produces a new
//! Mach-O file with that signature embedded. It performs no cryptography;
//! the detached signature must already be valid for the input.
//!
//! This crate is the build-time half of a signing workflow where the
//! cryptographic signing happens out-of-band (on a keyed workstation) and
//! the resulting signature is spliced into the final artifact hermetically
//! by a pure build step.

pub mod detached;
pub mod splice;

use anyhow::{Context as _, Result};
use apple_codesign::MachOBinary;

pub use detached::{parse_detached, pick_for_cpu, DetachedEntry};
pub use splice::embed_signature_in_macho;

/// Splice a detached signature into an unsigned thin Mach-O binary.
///
/// Parses the detached signature, locates the entry matching the Mach-O's
/// CPU type, and emits a new Mach-O with an embedded signature. Fails if
/// the Mach-O is a fat/universal binary (not yet supported).
pub fn embed_detached_into_macho(macho_bytes: &[u8], detached_bytes: &[u8]) -> Result<Vec<u8>> {
    let macho = MachOBinary::parse(macho_bytes).context("parsing input Mach-O")?;

    let cpu_type = macho.macho.header.cputype();
    let entries = parse_detached(detached_bytes).context("parsing detached signature")?;
    let blob = pick_for_cpu(&entries, cpu_type).context("selecting signature for CPU type")?;

    embed_signature_in_macho(&macho, blob).context("embedding signature into Mach-O")
}

/// Extract the embedded signature bytes from a signed Mach-O.
///
/// Returns the raw `CSMAGIC_EMBEDDED_SIGNATURE` (`0xfade0cc0`) SuperBlob
/// stored at `LC_CODE_SIGNATURE`. These bytes can be stored out-of-band
/// and later re-applied with [`embed_detached_into_macho`] to produce a
/// byte-identical signed binary.
pub fn extract_signature_from_macho(macho_bytes: &[u8]) -> Result<Vec<u8>> {
    let macho = MachOBinary::parse(macho_bytes).context("parsing signed Mach-O")?;

    let cmd = macho
        .code_signature_load_command()
        .context("Mach-O has no LC_CODE_SIGNATURE load command")?;

    let start = cmd.dataoff as usize;
    let end = start
        .checked_add(cmd.datasize as usize)
        .context("LC_CODE_SIGNATURE dataoff+datasize overflow")?;

    if end > macho_bytes.len() {
        anyhow::bail!(
            "LC_CODE_SIGNATURE references {start}..{end} but file is only {} bytes",
            macho_bytes.len()
        );
    }

    Ok(macho_bytes[start..end].to_vec())
}

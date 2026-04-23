// SPDX-License-Identifier: MPL-2.0

//! Round-trip fixture tests.
//!
//! Fixtures were generated from a KeePassXC.app main executable:
//!   - `unsigned.macho` — the linker-signed Mach-O as produced by nixpkgs
//!   - `sig.bin` — bare `CSMAGIC_EMBEDDED_SIGNATURE` bytes extracted from
//!     the output of `codesign -s - --force --identifier ... <bin>`
//!   - `expected-signed.macho` — the result of that same in-place
//!     `codesign -s -` invocation
//!
//! Invariant under test: `embed(unsigned, sig) == expected-signed`, and
//! `extract(expected-signed) == sig`.

use codesign_splice::{embed_detached_into_macho, extract_signature_from_macho};

const UNSIGNED: &[u8] = include_bytes!("fixtures/unsigned.macho");
const SIG: &[u8] = include_bytes!("fixtures/sig.bin");
const EXPECTED: &[u8] = include_bytes!("fixtures/expected-signed.macho");

#[test]
fn embed_produces_byte_identical_output() {
    let spliced = embed_detached_into_macho(UNSIGNED, SIG).expect("embed");
    assert_eq!(
        spliced.len(),
        EXPECTED.len(),
        "spliced size {} != expected {}",
        spliced.len(),
        EXPECTED.len()
    );
    assert!(spliced == EXPECTED, "spliced Mach-O differs from expected");
}

#[test]
fn extract_roundtrips_through_embed() {
    let extracted = extract_signature_from_macho(EXPECTED).expect("extract");
    assert_eq!(extracted, SIG, "extracted signature differs from fixture");

    let spliced = embed_detached_into_macho(UNSIGNED, &extracted).expect("embed extracted");
    assert!(spliced == EXPECTED, "extract-then-embed is not an identity");
}

#[test]
fn embed_twice_is_idempotent() {
    // Splicing the same sig into an already-signed Mach-O should produce
    // the same result as splicing into the unsigned original.
    let signed_once = embed_detached_into_macho(UNSIGNED, SIG).expect("first embed");
    let signed_twice = embed_detached_into_macho(&signed_once, SIG).expect("second embed");
    assert!(signed_once == signed_twice, "embed is not idempotent");
}

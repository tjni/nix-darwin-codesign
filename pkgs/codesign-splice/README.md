# codesign-splice

Splice precomputed Apple code signatures into Mach-O binaries, without any
cryptographic keys or network access.

The problem this solves: a Nix build cannot produce Apple Developer ID
signatures directly, because signing requires a private key (which must
not enter the Nix store) and an RFC 3161 timestamp (non-deterministic).
This tool factors signing into two steps:

1. **Out-of-band ceremony** (on a keyed workstation):
   `codesign -s "Developer ID..." --force --timestamp <binary>`, then
   `codesign-splice extract-signature --input <binary> --output <sig>` to pull
   the signature bytes out.
2. **Hermetic build** (in the Nix sandbox):
   `codesign-splice embed-signature --input <fresh-binary> --signature <sig> --output <signed>`
   produces a byte-identical signed Mach-O.

## Usage

```
codesign-splice extract-signature --input <signed-macho> --output <sig.bin>
codesign-splice embed-signature --input <unsigned-macho> --signature <sig.bin> --output <signed>
codesign-splice print-signature-info <sig-or-detached-file>
```

Subcommand names mirror [rcodesign][]'s conventions (`print-signature-info`,
`compute-code-hashes`, etc.) so this tool reads as a companion. If
`embed-signature` ever lands upstream in rcodesign, migration is a
binary-name swap, not a CLI redesign.

[rcodesign]: https://github.com/indygreg/apple-platform-rs

## What it is and isn't

- **Is**: a Mach-O surgeon. It resizes `__LINKEDIT`, updates
  `LC_CODE_SIGNATURE`, and writes a new Mach-O file.
- **Isn't**: a signer. It does no cryptography and holds no keys. The
  signature bytes are produced elsewhere by Apple's `codesign` (or
  equivalent, e.g. `rcodesign`).

## Signature format

The `.sig` file produced by `extract-signature` is a bare
`CSMAGIC_EMBEDDED_SIGNATURE` (`0xfade0cc0`) SuperBlob — literally the
bytes of the Mach-O's `LC_CODE_SIGNATURE` payload. Apple's native
`--detached` output (`CSMAGIC_DETACHED_SIGNATURE`, `0xfade0cc1`) is also
parsed but cannot be used for embedding: Apple's detached format is sized
for use as an external attachment, not for splicing, and its
CodeDirectory hashes a different Mach-O layout than what this tool would
produce.

## Testing

```
cargo test
```

Fixture-based round-trip tests verify that `embed-signature` produces
byte-identical output to `codesign -s -` for a known Mach-O.

## Related prior work

- [**rcodesign**][rcodesign] (indygreg) — cross-platform signer/verifier
  with most of Apple codesign's functionality. Provides our library deps
  (`apple-codesign` crate). Currently lacks an embed entry point for
  precomputed signatures.
- [**sigtool**][sigtool] (thefloweringash) — Mach-O signer focused on
  ad-hoc signing. Packaged as `pkgs.sigtool` in nixpkgs. Does not accept
  externally-computed signature blobs or handle CMS/Developer ID flows.

[sigtool]: https://github.com/thefloweringash/sigtool

## License

MPL-2.0. Portions of `src/splice.rs` are a public-API reimplementation
of `create_macho_with_signature` from the `apple-codesign` crate
(MPL-2.0); see the module header for attribution and upstream-sync
notes.

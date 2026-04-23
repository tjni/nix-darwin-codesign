# SPDX-FileCopyrightText: 2026 Theodore Ni <dev@ted.bio>
# SPDX-License-Identifier: MPL-2.0
{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "codesign-splice";
  version = "0.1.0";

  # `fileset` keeps build closure minimal (no target/ or ad-hoc
  # workspace junk). The actual crate sources are everything under
  # `src/` and `tests/` plus the Cargo manifest + lockfile.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
      ./tests
    ];
  };

  cargoLock.lockFile = ./Cargo.lock;

  # Round-trip fixture tests exercise embed + extract against a
  # known-good signed Mach-O. Keep enabled.
  doCheck = true;

  meta = {
    description = "Splice precomputed Apple code signatures into Mach-O binaries";
    longDescription = ''
      Embeds an Apple CSMAGIC_EMBEDDED_SIGNATURE blob produced
      externally (by `codesign` + a real signing identity + Apple's
      TSA) into an unsigned Mach-O. The tool does no cryptography
      and holds no keys; it's the build-time half of a split
      signing workflow where ceremony happens out-of-band and
      splice happens hermetically.

      Companion to rcodesign (apple-codesign crate). Subcommand
      naming mirrors rcodesign's conventions so migration to a
      future upstream `rcodesign embed-signature` is a binary-name
      swap.
    '';
    license = lib.licenses.mpl20;
    platforms = lib.platforms.unix;
    mainProgram = "codesign-splice";
  };
}

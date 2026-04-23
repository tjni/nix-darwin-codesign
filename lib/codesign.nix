# SPDX-FileCopyrightText: 2026 Theodore Ni <dev@ted.bio>
# SPDX-License-Identifier: MIT
#
# Splice precomputed Apple code signatures into an unsigned macOS
# bundle derivation. Runs entirely inside the Nix sandbox with no
# keys, no network, and no access to signing identities. The
# cryptographic signing happens out-of-band (in a per-package
# ceremony script); this helper just applies the resulting bytes
# deterministically so Nix builds stay hermetic and reproducible.
#
# Typical usage (from an overlay or package expression):
#
#   codesign = import ./lib/codesign.nix;
#   keepassxc = (codesign {
#     lib = pkgs.lib;
#     inherit (pkgs) stdenvNoCC codesign-splice;
#   }) {
#     signatures = ./pkgs/keepassxc/signatures;
#     provisioningProfile = ./pkgs/keepassxc/developer-id.provisionprofile;
#     bundleRelPath = "Applications/KeePassXC.app";
#   } unsignedDrv;
#
# The `signatures` directory is a tree mirroring the bundle's layout:
#
#   Contents/MacOS/KeePassXC.sig                  <- bare CSMAGIC_EMBEDDED_SIGNATURE
#   Contents/MacOS/keepassxc-cli.sig
#   Contents/PlugIns/libkeepassxc-autotype-cocoa.so.sig
#   Contents/_CodeSignature/CodeResources         <- bundle seal, verbatim
#
# Each `.sig` file is spliced into the Mach-O whose path matches
# minus the suffix. Non-`.sig` files under `Contents/` are copied
# verbatim. Files outside `Contents/` (e.g. `manifest.json`) are
# ignored so they don't end up as unsealed bundle content.
{
  lib,
  stdenvNoCC,
  codesign-splice,
}:

{
  # Path to a directory tree of signature files; see header comment
  # for the expected layout.
  signatures,

  # Relative path of the .app bundle inside the unsigned drv output.
  # e.g. "Applications/KeePassXC.app".
  bundleRelPath,

  # Optional Apple-issued provisioning profile. When supplied it's
  # installed at `Contents/embedded.provisionprofile`. When null,
  # any existing profile in the unsigned bundle is stripped (prevents
  # team-mismatch AMFI rejection from e.g. upstream-embedded profiles
  # belonging to a different Developer Team).
  provisioningProfile ? null,

  # Optional informational identity string (e.g. "Developer ID
  # Application: ... (TEAMID)"). Not verified; exposed in passthru.
  identity ? null,
}:

unsignedDrv:

stdenvNoCC.mkDerivation {
  pname = (unsignedDrv.pname or "bundle") + "-signed";
  version = unsignedDrv.version or "0";

  dontUnpack = true;
  dontBuild = true;
  dontConfigure = true;

  nativeBuildInputs = [ codesign-splice ];

  passthru = {
    unsigned = unsignedDrv;
    inherit signatures identity provisioningProfile;
  };

  installPhase = ''
    runHook preInstall

    # `-L`: dereference symlinks. The ceremony's `rsync
    # --copy-unsafe-links` collapses Qt plugin symlinks (pointing at
    # `/nix/store/...qtbase.../plugins/...`) into real files before
    # codesign seals the bundle; the committed CodeResources is
    # therefore keyed to those files' cdhashes, not to symlinks.
    # Preserving symlinks here breaks `codesign --verify` because the
    # walker can't reconcile "I hashed a file" with "here's a
    # symlink into the store."
    #
    # `--no-preserve=ownership` because we're not root and can't
    # set source's (nixbld) owner. Mode IS preserved (default) so
    # `launchd` can X_OK the executables.
    cp -RL --no-preserve=ownership ${unsignedDrv} $out
    chmod -R u+w $out

    bundle=$out/${bundleRelPath}

    # Replace or remove any existing embedded.provisionprofile.
    # Upstream nixpkgs builds of some apps (e.g. keepassxc) ship a
    # profile belonging to a different Apple Developer team. That
    # profile is not valid for any other signer and its presence
    # causes errSecMissingEntitlement (-34018) on biometric
    # Keychain calls; strip it unconditionally so the signer's own
    # profile (or no profile at all) is what macOS sees.
    rm -f "$bundle/Contents/embedded.provisionprofile"
    ${lib.optionalString (provisioningProfile != null) ''
      install -m 0444 "${provisioningProfile}" "$bundle/Contents/embedded.provisionprofile"
    ''}

    # Walk the signatures tree.
    sigsDir=${signatures}
    if [[ ! -d "$sigsDir" ]]; then
      echo "codesign: signatures directory $sigsDir missing or not a directory" >&2
      exit 1
    fi

    found_any=0
    while IFS= read -r src; do
      rel="''${src#$sigsDir/}"
      # Skip files outside Contents/ (e.g. manifest.json) — those are
      # ceremony bookkeeping, not bundle content.
      [[ "$rel" == Contents/* ]] || continue
      found_any=1
      if [[ "$rel" == *.sig ]]; then
        target_rel="''${rel%.sig}"
        target="$bundle/$target_rel"
        if [[ ! -f "$target" ]]; then
          echo "codesign: signature $rel references missing Mach-O $target_rel" >&2
          exit 1
        fi
        orig_mode=$(stat -c '%a' "$target")
        tmp=$(mktemp)
        codesign-splice embed-signature \
          --input "$target" \
          --signature "$src" \
          --output "$tmp"
        chmod "$orig_mode" "$tmp"
        mv "$tmp" "$target"
      else
        dst="$bundle/$rel"
        mkdir -p "$(dirname "$dst")"
        cp --no-preserve=mode "$src" "$dst"
        chmod 0444 "$dst"
      fi
    done < <(find "$sigsDir" -type f)

    if [[ $found_any -eq 0 ]]; then
      echo "codesign: signatures directory is empty; refusing to produce unsigned output" >&2
      exit 1
    fi

    runHook postInstall
  '';

  meta = (unsignedDrv.meta or { }) // {
    description = (unsignedDrv.meta.description or "") + " (signed)";
  };
}

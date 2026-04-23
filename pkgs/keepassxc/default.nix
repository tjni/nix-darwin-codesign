# SPDX-FileCopyrightText: 2026 Theodore Ni <dev@ted.bio>
# SPDX-License-Identifier: MIT
#
# Signed KeePassXC for Darwin. See ../../README.md for the
# per-signer onboarding flow.
{
  lib,
  stdenvNoCC,
  callPackage,
  codesign-splice,
  keepassxc,
  libsForQt5,
  lndir,
}:

let
  signer = builtins.fromJSON (builtins.readFile ../../signer.json);
  app = builtins.fromJSON (builtins.readFile ./app.json);
  inherit (app) bundleIdentifier;

  # Derived so the display string can't drift from teamId / name.
  identity = "Developer ID Application: ${signer.name} (${signer.teamId})";

  signaturesDir = ../../signatures/keepassxc;
  provisioningProfile = signaturesDir + "/developer-id.provisionprofile";

  entitlements = callPackage ../../lib/entitlements.nix {
    spec = builtins.fromJSON (builtins.readFile (signaturesDir + "/entitlements.json"));
  };

  unsignedDrv = callPackage ./unsigned.nix {
    inherit keepassxc libsForQt5 lndir bundleIdentifier;
  };

  codesign = import ../../lib/codesign.nix {
    inherit lib stdenvNoCC codesign-splice;
  };

  signedDrv = codesign
    {
      signatures = signaturesDir;
      inherit provisioningProfile;
      bundleRelPath = "Applications/KeePassXC.app";
      inherit identity;
    }
    unsignedDrv;
in
signedDrv.overrideAttrs (old: {
  passthru = (old.passthru or { }) // { inherit entitlements; };
})

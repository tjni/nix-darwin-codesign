# SPDX-FileCopyrightText: 2026 Theodore Ni <dev@ted.bio>
# SPDX-License-Identifier: MIT
#
# Classic (non-flake) entrypoint. See README.
{
  pkgs ? import <nixpkgs> { },
}:

let
  overlay = import ./overlay.nix;
  overlayed = pkgs.extend overlay;
in
{
  overlays.default = overlay;
  overlay = overlay;

  lib = import ./lib { inherit (pkgs) lib; };

  packages = {
    inherit (overlayed) codesign-splice;
  } // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
    inherit (overlayed) keepassxc;
  };
}

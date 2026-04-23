# SPDX-FileCopyrightText: 2026 Theodore Ni <dev@ted.bio>
# SPDX-License-Identifier: MIT
{
  description = "Apple Developer ID-signed variants of Darwin apps from nixpkgs, spliced hermetically";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      darwinSystems = [ "aarch64-darwin" "x86_64-darwin" ];
      forEach = systems: f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
    in
    {
      lib = import ./lib { lib = nixpkgs.lib; };

      overlays.default = import ./overlay.nix;

      packages = forEach darwinSystems (system: pkgs:
        let
          overlayed = pkgs.extend self.overlays.default;
        in
        {
          codesign-splice = overlayed.codesign-splice;
        });

      devShells = forEach darwinSystems (system: pkgs:
        let
          overlayed = pkgs.extend self.overlays.default;
        in
        {
          # bash and rsync pinned so signing ceremonies behave
          # identically across signer machines regardless of host
          # macOS version.
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.bash
              pkgs.rsync
              overlayed.codesign-splice
            ];
          };
        });
    };
}

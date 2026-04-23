# SPDX-FileCopyrightText: 2026 Theodore Ni <dev@ted.bio>
# SPDX-License-Identifier: MIT
{ lib }:
{
  # Build-time bundle signature splicer. callPackage-friendly; import
  # directly.
  codesign = import ./codesign.nix;

  # Renderer for runtime + profile entitlements plists from an inert
  # JSON spec. callPackage-friendly.
  entitlements = import ./entitlements.nix;
}

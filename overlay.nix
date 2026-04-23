# SPDX-FileCopyrightText: 2026 Theodore Ni <dev@ted.bio>
# SPDX-License-Identifier: MIT
#
# Guards use `prev.lib` / `prev.stdenv` rather than `final.*`:
# referencing `final.lib` inside an overlay's own body creates a
# fixpoint cycle and infinite recursion.
final: prev:
{
  codesign-splice = final.callPackage ./pkgs/codesign-splice { };
}
// prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
  # Pin to `prev.keepassxc` so callPackage doesn't recurse into our
  # own override. The unsigned source drv is at
  # `keepassxc.passthru.unsigned`.
  keepassxc = final.callPackage ./pkgs/keepassxc {
    keepassxc = prev.keepassxc;
  };
}

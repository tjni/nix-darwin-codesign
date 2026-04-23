# SPDX-FileCopyrightText: 2026 Theodore Ni <dev@ted.bio>
# SPDX-License-Identifier: MIT
final: prev: {
  codesign-splice = final.callPackage ./pkgs/codesign-splice { };
}

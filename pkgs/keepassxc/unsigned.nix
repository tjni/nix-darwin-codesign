# SPDX-FileCopyrightText: 2026 Theodore Ni <dev@ted.bio>
# SPDX-License-Identifier: MIT
#
# Two non-obvious overrides on top of nixpkgs' stock keepassxc:
#
# 1. CFBundleIdentifier is rewritten to the signer's App ID. Apple
#    reserves `org.keepassxc.keepassxc` to upstream's team, so any
#    re-signer needs their own reverse-DNS namespace.
#
# 2. qt.conf replaces makeBinaryWrapper. Only CFBundleExecutable
#    can claim profile-gated entitlements (Keychain access groups,
#    Touch ID Quick Unlock); the wrapper pattern puts the real Qt
#    binary at `.KeePassXC-wrapped`, which AMFI rejects for those
#    entitlements. Same pattern qgis uses.
{
  lib,
  keepassxc,
  libsForQt5,
  lndir,
  bundleIdentifier ? null,
}:

let
  inherit (libsForQt5) qtbase qtsvg qtdeclarative qttools;

  overrides = old: {
    # `preFixup = ""` suppresses upstream's explicit wrapQtApp call
    # that runs even when `dontWrapQtApps = true`.
    dontWrapQtApps = true;
    preFixup = "";

    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ lndir ];

    postInstall = (old.postInstall or "") + ''
      bundle=$out/Applications/KeePassXC.app
      mkdir -p "$bundle/Contents/PlugIns"
      lndir -silent ${qtbase.bin}/${qtbase.qtPluginPrefix} "$bundle/Contents/PlugIns"
      lndir -silent ${qtsvg.bin}/${qtbase.qtPluginPrefix} "$bundle/Contents/PlugIns"
      lndir -silent ${qtdeclarative.bin}/${qtbase.qtPluginPrefix} "$bundle/Contents/PlugIns"
      lndir -silent ${qttools.bin}/${qtbase.qtPluginPrefix} "$bundle/Contents/PlugIns"

      cat > "$bundle/Contents/Resources/qt.conf" <<'EOF'
      [Paths]
      Plugins = PlugIns
      EOF
    '';
  }
  // lib.optionalAttrs (bundleIdentifier != null) {
    postFixup = (old.postFixup or "") + ''
      # Info.plist's only occurrence of the upstream identifier is the
      # CFBundleIdentifier value itself, so a global substituteInPlace
      # is safe.
      plist="$out/Applications/KeePassXC.app/Contents/Info.plist"
      substituteInPlace "$plist" \
        --replace-fail "org.keepassxc.keepassxc" ${lib.escapeShellArg bundleIdentifier}
    '';
  };
in
keepassxc.overrideAttrs overrides

#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Theodore Ni <dev@ted.bio>
# SPDX-License-Identifier: MIT
#
# KeePassXC signing ceremony. See ../../README.md for how the
# signatures it produces are later consumed by lib/codesign.nix.

set -euo pipefail

pkg_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$pkg_dir/../.." && pwd)
sig_root=$repo_root/signatures/keepassxc

# --- knobs (overridable via env) -----------------------------------------
: "${KEEPASSXC_P12_FILE:=$HOME/.config/sops-nix/secrets/apple/developer-id-p12-base64}"
: "${KEEPASSXC_P12_PASSWORD_FILE:=$HOME/.config/sops-nix/secrets/apple/developer-id-p12-password}"
: "${KEEPASSXC_INSTALLED_PATH:=$HOME/Applications/KeePassXC.app}"
: "${KEEPASSXC_SIG_DIR:=$sig_root}"

# Developer ID Direct provisioning profile. Required for Touch ID
# Quick Unlock; a committed profile under $sig_root is the default.
# No env override for the signer identity itself — entitlements.nix
# renders from the same constant, and letting them diverge would
# silently produce a bundle signed under one team and entitled under
# another.
if [[ -z "${KEEPASSXC_PROFILE-}" ]]; then
    if [[ -f "$sig_root/developer-id.provisionprofile" ]]; then
        KEEPASSXC_PROFILE="$sig_root/developer-id.provisionprofile"
    else
        KEEPASSXC_PROFILE=""
    fi
fi

# --- pre-flight ----------------------------------------------------------
if [[ ! -r "$KEEPASSXC_P12_FILE" ]]; then
    echo "error: p12 file not readable: $KEEPASSXC_P12_FILE" >&2
    echo "(sops-nix must have deployed the secret; try running darwin-rebuild switch once)" >&2
    exit 1
fi
if [[ ! -r "$KEEPASSXC_P12_PASSWORD_FILE" ]]; then
    echo "error: p12 password file not readable: $KEEPASSXC_P12_PASSWORD_FILE" >&2
    exit 1
fi

# --- resolve signer identity from Nix -------------------------------------
identity=$(nix eval --raw "$repo_root#keepassxc.passthru.identity") || {
    echo "error: failed to eval signer identity from default.nix" >&2
    exit 1
}
echo "=> signer identity: $identity"

# --- build prerequisites --------------------------------------------------
echo "=> building unsigned KeePassXC + codesign-splice + entitlements..."
mapfile -t build_outs < <(
    nix build --no-link --print-out-paths \
        "$repo_root#keepassxc.passthru.unsigned" \
        "$repo_root#codesign-splice" \
        "$repo_root#keepassxc-entitlements-runtime" \
        "$repo_root#keepassxc-entitlements-bundle-executable"
) || { echo "error: failed to build prerequisites" >&2; exit 1; }
unsigned=${build_outs[0]}
splicer=${build_outs[1]}/bin/codesign-splice
runtime_ent_file=${build_outs[2]}
bundle_exe_ent_file=${build_outs[3]}
echo "   unsigned:       $unsigned"
echo "   splicer:        $splicer"
echo "   runtime ent:    $runtime_ent_file"
echo "   main-exe ent:   $bundle_exe_ent_file"

# --- stage a writable copy ------------------------------------------------
staging=$(mktemp -d -t keepassxc-signing.XXXXXXXX)
bundle=$staging/KeePassXC.app
echo "=> staging bundle at $bundle"
rsync -a --copy-unsafe-links "$unsigned/Applications/KeePassXC.app/" "$bundle/"
# Nix store outputs arrive mode 555; make the whole tree user-writable
# so codesign can replace existing signatures.
chmod -R u+w "$bundle"

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")
if [[ -z "$bundle_id" ]]; then
    echo "error: could not read CFBundleIdentifier from $bundle/Contents/Info.plist" >&2
    exit 1
fi
echo "=> bundle id: $bundle_id"

# Upstream's profile is for team G2S7P7J672, which mismatches our
# Developer ID and causes errSecMissingEntitlement on biometric
# SecItemAdd. Strip unconditionally; lib/codesign.nix does the same
# at Nix build time — keep both sides aligned.
rm -f "$bundle/Contents/embedded.provisionprofile"
if [[ -n "$KEEPASSXC_PROFILE" ]]; then
    if [[ ! -r "$KEEPASSXC_PROFILE" ]]; then
        echo "error: provisioning profile not readable: $KEEPASSXC_PROFILE" >&2
        exit 1
    fi
    cp "$KEEPASSXC_PROFILE" "$bundle/Contents/embedded.provisionprofile"
    chmod 0444 "$bundle/Contents/embedded.provisionprofile"
    echo "=> embedded provisioning profile from $KEEPASSXC_PROFILE"
fi

# --- temp keychain -------------------------------------------------------
p12=$(mktemp -t keepassxc-p12.XXXXXXXX)
kc=$(mktemp -u -t keepassxc-kc.XXXXXXXX).keychain-db
kc_pw=$(openssl rand -base64 24)
# Capture the current user search list so we can restore it on exit.
read -r -d '' -a prior_keychains < <(
    /usr/bin/security list-keychains -d user \
        | tr -d '"' \
        | tr -d ' '
) || true

cleanup() {
    rm -f "$p12"
    /usr/bin/security list-keychains -d user -s "${prior_keychains[@]}" >/dev/null 2>&1 || true
    /usr/bin/security delete-keychain "$kc" >/dev/null 2>&1 || true
    rm -rf "$staging"
}
trap cleanup EXIT

/usr/bin/base64 -d < "$KEEPASSXC_P12_FILE" > "$p12"
/usr/bin/security create-keychain -p "$kc_pw" "$kc" >/dev/null
/usr/bin/security unlock-keychain -p "$kc_pw" "$kc"
/usr/bin/security list-keychains -d user -s "$kc" "${prior_keychains[@]}" >/dev/null
/usr/bin/security import "$p12" -f pkcs12 -k "$kc" \
    -P "$(cat "$KEEPASSXC_P12_PASSWORD_FILE")" \
    -T /usr/bin/codesign >/dev/null
/usr/bin/security set-key-partition-list \
    -S 'apple-tool:,apple:,codesign:' -s -k "$kc_pw" "$kc" >/dev/null

if ! /usr/bin/security find-identity -v -p codesigning "$kc" | grep -Fq -- "$identity"; then
    echo "error: identity '$identity' not found in temp keychain" >&2
    echo "--- find-identity output:" >&2
    /usr/bin/security find-identity -v -p codesigning "$kc" >&2
    exit 1
fi

# --- sign inside-out ------------------------------------------------------
sign_opts=(
    --force
    --options runtime
    --timestamp
    --sign "$identity"
    --keychain "$kc"
)

# Helpers (plugin + proxy + cli) get runtime-only entitlements;
# profile-gated entitlements on helper Mach-Os would trip AMFI
# SIGKILL since the profile only authorizes them for
# CFBundleExecutable. The main exe picks up profile-gated
# entitlements via the bundle seal below.
# Qt plugins under PlugIns/ arrive ad-hoc signed by nixpkgs and
# are not re-signed.

echo "=> signing keepassxc plugin (libkeepassxc-autotype-cocoa.so)..."
/usr/bin/codesign "${sign_opts[@]}" --entitlements "$runtime_ent_file" \
    "$bundle/Contents/PlugIns/libkeepassxc-autotype-cocoa.so"

for rel in Contents/MacOS/keepassxc-proxy Contents/MacOS/keepassxc-cli; do
    echo "=> signing $rel with runtime-only entitlements..."
    /usr/bin/codesign "${sign_opts[@]}" --entitlements "$runtime_ent_file" "$bundle/$rel"
done

echo "=> sealing bundle (main executable gets full profile-gated entitlements)..."
/usr/bin/codesign "${sign_opts[@]}" \
    --identifier "$bundle_id" \
    --entitlements "$bundle_exe_ent_file" \
    "$bundle"

# --- verify before extraction --------------------------------------------
echo "=> verifying signed bundle..."
/usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle" || {
    echo "error: signed bundle fails verification; aborting extraction" >&2
    exit 1
}

# --- extract signatures ---------------------------------------------------
echo "=> extracting signatures to $KEEPASSXC_SIG_DIR"
# Clean just the ceremony-generated subtree; the provisioning
# profile co-located in $KEEPASSXC_SIG_DIR is signer-supplied input,
# not ceremony output, and must survive.
rm -rf "$KEEPASSXC_SIG_DIR/Contents" "$KEEPASSXC_SIG_DIR/manifest.json"
mkdir -p "$KEEPASSXC_SIG_DIR"

# Plugin symlinks under PlugIns/ point into ad-hoc-signed nix-store
# outputs — skip those and extract only the real .so files we signed.
macho_list=(
    Contents/MacOS/KeePassXC
    Contents/MacOS/keepassxc-cli
    Contents/MacOS/keepassxc-proxy
)

shopt -s nullglob
for so in "$bundle"/Contents/PlugIns/*.so; do
    [[ -f "$so" && ! -L "$so" ]] || continue
    macho_list+=( "${so#"$bundle"/}" )
done

for rel in "${macho_list[@]}"; do
    sig_out=$KEEPASSXC_SIG_DIR/$rel.sig
    mkdir -p "$(dirname "$sig_out")"
    echo "   extract: $rel"
    "$splicer" extract-signature --input "$bundle/$rel" --output "$sig_out"
done

# Bundle seal: copy CodeResources verbatim.
mkdir -p "$KEEPASSXC_SIG_DIR/Contents/_CodeSignature"
cp "$bundle/Contents/_CodeSignature/CodeResources" \
   "$KEEPASSXC_SIG_DIR/Contents/_CodeSignature/CodeResources"
chmod 0444 "$KEEPASSXC_SIG_DIR/Contents/_CodeSignature/CodeResources"

# --- manifest -------------------------------------------------------------
echo "=> writing manifest"
unsigned_hash=$(basename "$unsigned" | cut -d- -f1)
signed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$KEEPASSXC_SIG_DIR/manifest.json" <<EOF
{
  "unsigned_drv_output": "$unsigned",
  "unsigned_output_hash": "$unsigned_hash",
  "installed_path": "$KEEPASSXC_INSTALLED_PATH",
  "identity": "$identity",
  "signed_at_utc": "$signed_at"
}
EOF

echo ""
echo "done. signatures committed to $KEEPASSXC_SIG_DIR"
echo "$(find "$KEEPASSXC_SIG_DIR" -type f | wc -l | tr -d ' ') files written."

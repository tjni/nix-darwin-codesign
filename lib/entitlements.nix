# SPDX-FileCopyrightText: 2026 Theodore Ni <dev@ted.bio>
# SPDX-License-Identifier: MIT
#
# Renders a pair of entitlements plists from an inert spec (per
# `signatures/<name>/entitlements.json`):
#
#   {
#     "runtime": { <apple key>: <plist value>, ... },
#     "bundleExecutable": { <apple key>: <plist value>, ... }
#   }
#
# `runtime` entries apply to every Mach-O in the bundle (hardened-
# runtime baseline).
#
# `bundleExecutable` entries apply ONLY to the Mach-O named by
# `CFBundleExecutable`. AMFI SIGKILLs helper binaries that claim
# profile-gated entitlements (`com.apple.application-identifier`,
# `keychain-access-groups`), because the embedded provisioning
# profile only authorizes them for the bundle's main exe.
#
# Values map 1:1 onto plist scalars (booleans, strings, arrays).
{
  lib,
  writeText,
  spec,
}:

let
  toPlist = lib.generators.toPlist { escape = true; };
  runtime = spec.runtime or { };
  bundleExecutable = runtime // (spec.bundleExecutable or { });
in
{
  runtime = writeText "runtime.entitlements" (toPlist runtime);
  bundleExecutable = writeText "bundle-executable.entitlements" (toPlist bundleExecutable);
}

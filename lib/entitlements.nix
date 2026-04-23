# SPDX-FileCopyrightText: 2026 Theodore Ni <dev@ted.bio>
# SPDX-License-Identifier: MIT
#
# Renders a pair of entitlements plists from an inert spec. The spec
# shape (per `signatures/<name>/entitlements.json`):
#
#   {
#     "runtime": { <literal plist keys> },
#     "profileFeatures": { <feature name>: bool, ... }
#   }
#
#   runtime          static entitlements that go on every Mach-O in
#                    the bundle.
#   profileFeatures  flags for signer-dependent entitlements that
#                    only go on the CFBundleExecutable (main exe).
#                    AMFI SIGKILLs helper Mach-Os that claim these,
#                    because the provisioning profile only authorizes
#                    them for the main exe. Recognized features are
#                    hardcoded below; add here as new apps need them.
{
  lib,
  writeText,
  spec,
  appId,
  hasProvisioningProfile,
}:

let
  toPlist = lib.generators.toPlist { escape = true; };

  features = spec.profileFeatures or { };

  profileExtras =
    lib.optionalAttrs (features.applicationIdentifier or false) {
      "com.apple.application-identifier" = appId;
    }
    // lib.optionalAttrs ((features.keychainAccessGroups or false) && hasProvisioningProfile) {
      "keychain-access-groups" = [ appId ];
    };

  runtime = spec.runtime or { };
  profile = runtime // profileExtras;
in
{
  runtime = writeText "runtime.entitlements" (toPlist runtime);
  profile = writeText "profile.entitlements" (toPlist profile);
}

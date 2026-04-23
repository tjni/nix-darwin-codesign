# nix-darwin-codesign

A Nix overlay that ships Developer ID-signed variants of nixpkgs Darwin
applications, spliced hermetically into the Nix build. No keys in the
sandbox, no network access, no per-host signing dance — signatures are
produced once by an out-of-band ceremony, committed to this repo, and
applied deterministically when the package is built.

## What this buys you

For apps that need macOS runtime capabilities gated on Developer ID
signing — Touch ID Quick Unlock, TCC grants that survive rebuilds,
Keychain access groups, Gatekeeper-quiet launches — this overlay
closes the gap between "built from source via nixpkgs" and "runs like
a notarized release."

For apps that don't need those capabilities, this overlay is
unnecessary; the nixpkgs stock build is fine.

## Packages

None yet. See [`docs/proposal.md`](docs/proposal.md) for the design
and the per-package recipe; contributions for Darwin-signed apps
are welcome.

## Caveats on re-use

The committed signatures and embedded provisioning profiles in this
repo are **this signer's** (Theodore Ni, team `5KA3K776LM`). If you
want the same apps signed for your own distribution, you'll need to
fork and run the ceremony against your own Apple Developer team. See
[`docs/proposal.md`](docs/proposal.md) §5 for the identity story and
what it means for forks.

Reasons you might use this overlay **without forking**:
- You specifically trust this signer's provenance of rebuilt Darwin
  binaries from nixpkgs.
- You're experimenting with the architecture and want a working
  reference.
- You're a developer on this overlay.

Reasons you probably want to fork:
- You have your own Apple Developer account and want signatures from
  your own team.
- Your threat model doesn't accept a third party re-signing binaries
  on your behalf.

## Installation

### Nix flakes

```nix
{
  inputs.nix-darwin-codesign.url = "github:tjni/nix-darwin-codesign";
  inputs.nix-darwin-codesign.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nixpkgs, nix-darwin-codesign, ... }: {
    darwinConfigurations.myhost = darwin.lib.darwinSystem {
      modules = [
        { nixpkgs.overlays = [ nix-darwin-codesign.overlays.default ]; }
        # ... rest of config
      ];
    };
  };
}
```

### Classic Nix overlay

```nix
{
  nixpkgs.overlays = [
    (import (builtins.fetchTarball "https://github.com/tjni/nix-darwin-codesign/archive/main.tar.gz"))
  ];
}
```

Applying the overlay is a no-op until a signed-variant package is
added (see [`docs/proposal.md`](docs/proposal.md) §3 for the recipe).

## Running a signing ceremony (per-package)

Each package has a `sign.sh` script that:
1. Builds the unsigned derivation
2. Decrypts the signer's p12 from sops-nix-deployed secrets
3. Creates a temporary keychain + imports the cert
4. Signs every Mach-O in the bundle with the expected entitlements
5. Extracts signatures via `codesign-splice`
6. Writes them under `signatures/<name>/`

To re-sign after a nixpkgs bump, run `pkgs/<name>/sign.sh`.

## Architecture

See [`docs/proposal.md`](docs/proposal.md) for:
- Security posture and trust model
- Threat model
- Why the wrapper / qt.conf swap is needed on Darwin
- Per-signer App ID namespace requirements
- Nixpkgs upstreamability path

## License

MIT (code). Signatures under `signatures/*/` are deterministic
functions of upstream source + signer identity; the copyright on
upstream source is upstream's.

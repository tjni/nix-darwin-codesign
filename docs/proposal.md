# Proposal: Hermetic Apple Developer ID Signing for Nixpkgs

Status: draft, pre-RFC
Audience: nixpkgs maintainers, darwin users, future upstream reviewers
Author: Theodore Ni
Working directory: `~/.config/dotfiles` (prototype lives here, upstream target is nixpkgs)

## 1. Motivation

**Goal**: software packaged through nixpkgs for macOS should be fully
functional for end users. Signing is a means to that end, not an end in
itself.

"Fully functional" specifically means parity with upstream-distributed
binaries along a few axes:

- **Gatekeeper launch**: apps can be opened via Finder without per-user
  right-click-Open rituals or `spctl --add` exceptions.
- **TCC grants**: the system's privacy consent UI works the way users
  expect. TCC identifies apps by a tuple of (bundle identifier, code
  requirement). Ad-hoc and linker-signed binaries change their code
  requirement on every rebuild, so TCC grants evaporate on `nixos-rebuild
  switch`. Developer ID stabilizes the code requirement.
- **Identity-gated OS capabilities**: Keychain access groups (shared
  `Touch ID`-unlocked password storage), cross-app automation, hardened-
  runtime entitlements, ES/ALT clients — all refuse to work under ad-hoc
  signing, by design.
- **Absence of per-host workarounds**: activation scripts that re-sign
  post-install are non-hermetic, fight consumer sync tools (Google Drive
  treats re-signed files as delete+create, trashing file IDs), and
  require ambient signing credentials on every host.

What this is **not** about:

- Not primarily about security. Nixpkgs' existing trust model (source
  hashing, reproducible builds, reviewer-gated commits) is the substrate;
  signing adds a narrow supply-chain-integrity layer on top. See §2.
- Not about making nixpkgs' Darwin apps more trustworthy than upstream's.
  It's about making them not *less* functional.
- Not about distributing pre-built binaries more safely. Nix's content-
  addressed store and cache substitution already cover that. Gatekeeper
  and TCC are separate OS-level gates that live outside nix's trust chain.

### Technical obstacles

Developer ID signatures require:
- A private key (must not enter the Nix store)
- A timestamp from Apple's TSA (network access, non-deterministic)
- A `signingTime` CMS signed-attribute (non-deterministic per-invocation)

A fully hermetic, reproducible Nix build cannot produce such a signature
itself. This proposal factors the problem so Nix doesn't have to.

## 2. Security posture and trust model

### What a Developer ID signature actually means

Before discussing the nixpkgs-specific model, it's worth pinning down what
Apple's own signing model asserts — because it's easy to over-read.

**Ad-hoc signing** (the baseline) does two things: it produces a stable code
hash and provides tamper detection. The signature is anonymous. On Apple
Silicon, ad-hoc (or linker-signed) signing is a kernel-enforced requirement
for any binary to execute at all ([Oakley 2020][oakley-arm64]). macOS sees
"some code with a stable cdhash" and nothing more.

**Developer ID signing** adds one thing that matters above all others:
**identity with accountability**. Apple's enrollment process verifies the
developer's legal identity — legal name, organization binding authority,
D-U-N-S for organizations ([Apple Developer Program identity
verification][apple-identity-verification]). The resulting cert binds a real
legal entity to the binary, and Apple retains the ability to revoke that
cert if the developer ships malware
([Apple Platform Security: malware protection][aps-malware]).

What Developer ID does **not** assert:

- **Code correctness**: Apple does not audit the source code. The
  identity-verification process checks who you are, not what your code does.
- **Behavioral safety**: even notarization is an automated scan for known
  malicious patterns, not a security review
  ([Apple Platform Security: Gatekeeper][aps-gatekeeper],
  [Oakley 2020: how notarization works][oakley-notarization]). Notarized
  malware has repeatedly escaped detection
  ([Wardle, "Apple Approved Malware"][wardle-approved-malware]).

Beyond identity, Developer ID also provides:

- **A stable code requirement, decoupled from cdhash**. TCC and other
  subsystems identify apps by a logical predicate over the signature (team
  identifier + bundle identifier + cert anchor), not by raw code hash. This
  is why TCC grants survive app updates under Developer ID but not ad-hoc
  ([Apple TN2206][tn2206], [Oakley: signing and privacy control][oakley-tcc]).
- **Team-ID-scoped capabilities**. Keychain access groups, App Groups,
  associated domains, and similar facilities are namespaced to a Team ID
  and simply don't function with ad-hoc signing
  ([Apple Platform Security: app code signing][aps-code-signing],
  [Apple: sharing keychain items][apple-keychain-sharing]).
- **Identity-gated entitlements**. Many hardened-runtime entitlements
  (JIT, disable-library-validation, etc.) only take effect when claimed in
  a Developer ID-signed binary ([Apple: Hardened Runtime][apple-hardened],
  [Apple: Entitlements][apple-entitlements]).

**The philosophical core**: a Developer ID signature converts *anonymous
code* into *identified and accountable code*. The technical machinery —
cert chains, RFC 3161 timestamps ([IETF RFC 3161][rfc3161]), revocation —
is infrastructure for one purpose: a named party has something to lose if
they misbehave, and macOS has a way to enforce that loss. macOS subsystems
extend capabilities (TCC grants, Keychain access, hardened entitlements)
because there is an accountable party to hold responsible for their use.

Ad-hoc signing asserts only tamper detection. Developer ID asserts identity,
accountability, and — by extension — the predicate under which macOS is
willing to grant full capabilities.

### What Apple's model assumes vs. what nixpkgs distribution is

The conventional Apple model assumes the developer of the software and the
signer of the binary are the same entity. "Developer ID" is literal — the
signature names the author. This conflates three distinct warrants into one:

1. **Authorship warrant**: "I wrote (or chose to include) this code."
2. **Build-integrity warrant**: "This binary was produced faithfully from
   that source code."
3. **Distribution-integrity warrant**: "This binary reaches the user
   without post-build modification."

Upstream-distributed Developer ID binaries bundle all three under one
signature. The user trusts Apple's cert chain + the developer's identity to
cover all three.

**Nixpkgs' distribution model separates these warrants**:

- Authorship warrant stays with **upstream**. Nixpkgs doesn't author the
  software; it packages it. The source hash (`sha256` on the fetched
  source tarball/commit) is nixpkgs' way of saying "these exact source
  bytes are what we packaged."
- Build-integrity warrant stays with **nixpkgs' build infrastructure**.
  Hydra builds from hashed inputs in a sandbox and signs its cache
  artifacts with a cache signing key. That signature is Nix-level and
  verified by `nix-daemon`, not macOS.
- Distribution-integrity warrant, at the macOS layer, is what a Developer
  ID signature would provide. Without it, macOS has no way to verify that
  the binary in the user's `/nix/store` is the one nixpkgs' build produced
  — Gatekeeper and TCC operate outside nix's trust chain.

So: **a Developer ID signature on a nixpkgs-built binary attests
distribution-integrity at the macOS boundary. It does not attest authorship
or behavioral correctness, and should not be interpreted that way by users
or by signers.**

### What the signer warrants, honestly

Concretely, a signer of `nixpkgs-darwin-signed` warrants:

- "This signature corresponds to the unsigned output of nixpkgs build
  script `<path>` at commit `<hash>`, with source hash `<sha256>`."
- "Between that build output and this signed artifact, I did not modify
  the binary's code, resources, or metadata. The only difference is the
  embedded signature."
- "The entitlements claimed match upstream's design (or, if they differ,
  the delta is documented in this package's `signatures.nix`)."

The signer does **not** warrant:

- "I have audited upstream's source code for security bugs." (Neither does
  any nixpkgs maintainer for any package.)
- "The software does only what upstream claims." (Upstream's
  responsibility, mediated by source auditability.)
- "The nixpkgs build script is correct or safe." (Nixpkgs maintainers'
  responsibility.)

This is the same shape of warrant that
[reproducible-builds.org][rb-org] and the
[Debian reproducible-builds project][debian-rb] make: "independent
verifications that a binary matches what the source intended to produce."
Provenance integrity, not behavioral attestation. Developer ID is just the
macOS-native transport for that warrant; it carries the same class of
claim in a format Gatekeeper and TCC understand.

### How this composes with nixpkgs' existing guarantees

| Layer                | Guarantee                              | Who    | Verified by          |
|----------------------|----------------------------------------|--------|----------------------|
| Source hash          | Upstream source is bit-identical       | Nix    | `nix-daemon`         |
| Reproducible build   | Build output is a function of inputs   | Nix    | `nix-daemon`         |
| Cache signing        | Substituted artifacts are Hydra's      | Nix    | `nix-daemon`         |
| Developer ID (new)   | Store artifact reached user unmodified | Signer | Gatekeeper, TCC      |

These layers are complementary. Dropping Developer ID doesn't weaken the
nix layers. Adding Developer ID doesn't strengthen them — it extends
integrity into macOS' runtime-gate layer.

### Entitlements policy

Entitlements are capability grants. Claiming them is a design statement:
"this app uses these OS facilities for these purposes." The signer of a
re-packaged binary has to decide which entitlements to embed.

**Policy**: the signer's default should be **to mirror upstream's
entitlements as published in upstream's signed release**. Deviations:

- **Removing** an entitlement upstream claims: generally safe, reduces
  attack surface, but may break the app. Document why.
- **Adding** an entitlement upstream does not claim: requires explicit
  justification. Expanding attack surface beyond what upstream chose is a
  substantive change and should be reviewed as such.
- **Changing team-identifier-scoped entitlements**: some entitlements
  (Keychain access groups, App Groups) are namespaced to the signer's
  Team ID. If the signer's Team ID differs from upstream's, any
  Keychain-group values from upstream won't work verbatim — they'd need
  to be rewritten to the signer's Team ID. This is a real divergence
  (user data migration implications) and should be called out.

`signatures.nix` for each package committed to the overlay should include
a machine-readable entitlements manifest alongside the plist files, so
reviewers and users can diff against upstream.

### Threat model

What this proposal mitigates, beyond status quo:

- **Post-build tampering in the Nix store**: a local attacker with write
  access to `/nix/store` who swaps a Mach-O. Gatekeeper (after Developer
  ID is in place) refuses to launch the modified binary on next start.
  Ad-hoc-signed binaries don't provide this.
- **Compromised binary substituter / cache MITM**: if an attacker serves
  a malicious replacement via cache substitution, Nix's cache signature
  would already catch it at pull time — but if that check is bypassed or
  misconfigured, Gatekeeper adds a second barrier at launch.
- **TCC grant theft**: if an attacker plants a binary at the expected
  path with the same bundle ID but different code, current ad-hoc signing
  means TCC re-prompts (annoying) or silently grants based on path
  (depending on macOS version). Stable Developer ID code requirements
  make TCC's identification precise.

What this does not mitigate:

- **Compromised nixpkgs commit**: an attacker who lands a malicious
  nixpkgs PR. The signer will sign the resulting (malicious) build,
  because the signer warrants build-output integrity, not commit
  authenticity. Orthogonal mitigation: nixpkgs commit signing, two-person
  PR review.
- **Compromised upstream source**: upstream pushes a malicious release.
  The source hash matches (it's what was published), the build is
  reproducible (it's what nixpkgs' script produced), the signer signs it.
  Orthogonal mitigation: upstream's own release process, downstream
  security advisories.
- **Compromised signer workstation**: key exfiltration from the signer's
  machine lets an attacker issue new signatures in the signer's name.
  Mitigation: hardware token / Secure Enclave storage of the key, signer
  workstation hygiene, quick revocation.
- **Compromised build tool**: a malicious Rust compiler or stdenv could
  tamper during build. Nixpkgs' existing threat model already applies.

What this introduces as new risk:

- **Signer impersonation or key leak**: a new point of failure. Mitigated
  by: hardware-backed key storage, published `SIGNERS.md`,
  prompt revocation, multi-signer/federation for defense in depth.
- **Misinterpretation of the warrant**: users may assume a Developer ID
  signature on a nixpkgs build means upstream endorsed it, or that
  nixpkgs has audited it. Mitigation: clear docs, signer-identifying
  display to users (Apple's UI already names the signer — "Developer ID
  Application: Jane Doe (TEAMID)" — so users see a nixpkgs packager's
  name, not the upstream's).

### The "nixpkgs developers cannot guarantee invariants at scale" problem

This is the hardest point. Nixpkgs has ~100k derivations. No human can
audit them. Signing a binary with a Developer ID attaches the signer's
name and legal identity to that binary. If the signer signs a malicious
nixpkgs build, even inadvertently, they have publicly attested provenance
on malware.

Three mitigations, layered:

1. **Restrict scope aggressively.** The overlay covers a curated list of
   user-requested GUI apps (see §7). Not tree-wide. The signer
   can reasonably track diffs to ~30 packages; they cannot track ~10k.

2. **Automate the "I didn't modify it" warrant.** Signing should be a
   mechanical pipeline: `unsigned-drv → detached-sig`. The signer's
   workstation runs a script that takes the unsigned drv hash, verifies
   it against nixpkgs' Hydra cache signature (so the signer knows they're
   signing what Hydra built, not a local fork), and produces detached
   sigs. The signer's attention-budget is spent on "is this the nixpkgs
   output I expect?" not "is this binary safe?"

3. **Make the warrant explicit in user-visible metadata.** The signer's
   Developer ID common name should make the provenance clear — e.g.,
   "Developer ID Application: Theodore Ni (nixpkgs-darwin-signed)
   (TEAMID)" if Apple allowed arbitrary CN, which they don't — so the
   next best thing is published `SIGNERS.md` + overlay docs that make it
   impossible for a reasonable user to misread the signature as upstream
   endorsement.

The intellectually honest version: **the signer is making a promise they
can actually keep (build-output integrity), and users consuming the
overlay are choosing to trust that promise**. Anything stronger — code
auditing, behavior attestation — is outside the overlay's contract and
should be explicitly disclaimed.

### Bring-your-own-signature mode

Not everyone needs the community overlay. A user or organization with
their own Developer ID can use the same `codesign` helper + `codesign-sign`
wrapper to produce private signatures for their own fleet. This is the
expected mode for:

- Individual developers signing their daily-driver machine
- Organizations deploying nixpkgs-based Darwin builds internally (MDM,
  shared fleet)
- Ad-hoc experimentation before upstreaming anything

In this mode, the trust model is trivial: the user trusts themselves.
The overlay is just the community flavor of the same mechanism.

## 3. Key insight

Developer ID signing decomposes into:

- **Deterministic data**: CodeDirectory, entitlements blob, requirements blob, `CodeResources` manifest. All are pure functions of bundle contents + identity metadata + entitlements plist.
- **Non-deterministic data**: the CMS blob (cert chain + signed CD hash + RFC 3161 timestamp + `signingTime`). ~6-9 KB per Mach-O.

If the CMS blob is produced by an external signing ceremony and committed as
static data, a Nix build can reassemble a signed Mach-O deterministically by
splicing the precomputed signature into the unsigned output. This separates
"what requires a key" from "what requires a Nix sandbox", satisfying both
constraints.

Apple's native `CSMAGIC_DETACHED_SIGNATURE` format (`fade0cc1`) packages an
entire embedded signature (CodeDirectory + entitlements + requirements + CMS)
as a standalone blob. This is the natural on-disk format for committed
signatures.

## 4. Architecture

### Triple of derivations, per-package

```
pkgs.<name>-unsigned   : always builds, input to signing
pkgs.<name>-signatures : data-only drv wrapping committed sig files
pkgs.<name>            : final artifact (on Darwin: signed; on Linux: = unsigned)
```

### Two pieces of shared tooling

- `pkgs.codesign`: pure Nix helper (`{ signatures }: unsigned: signedDrv`).
  Splices detached signatures into Mach-Os, verifies cdhashes, runs
  `codesign --verify --deep --strict` as a smoke test on Darwin. Fails the
  build on any inconsistency. Written in Rust atop `apple-codesign` crate.

- `pkgs.codesign-sign`: external signing ceremony runner. A script (Rust or
  shell) that takes unsigned drv + identity + cert + entitlements map and
  produces a populated signatures directory + manifest. Requires network
  (TSA) and key material. Runs on a signer's workstation, not in any Nix
  sandbox.

### Data flow

```
                      ┌───────────────────────────────────┐
                      │   signing ceremony (keyed human)  │
                      │                                   │
   <name>-unsigned ──▶│ codesign-sign ──▶ signatures/     │
                      │                     manifest.json │
                      └───────────────────┬───────────────┘
                                          │ commit
                                          ▼
                             pkgs.<name>-signatures
                                          │
                         ┌────────────────┴──────────┐
                         │   Nix build (hermetic)    │
   <name>-unsigned ────▶ │  pkgs.codesign splicer    │ ───▶ <name>
                         └───────────────────────────┘
```

## 5. Naming and identity

### The pname question

Concrete options for how `pname` flows through the triple:

**Option A — Distinct pname, matching `-unwrapped` convention**

| platform | attr              | pname                 | store path                     |
|----------|-------------------|-----------------------|--------------------------------|
| Darwin   | `keepassxc-unsigned` | `keepassxc-unsigned` | `HASH1-keepassxc-unsigned-2.7.12` |
| Darwin   | `keepassxc`       | `keepassxc`           | `HASH2-keepassxc-2.7.12`          |
| Linux    | `keepassxc-unsigned` | `keepassxc-unsigned` | `HASH3-keepassxc-unsigned-2.7.12` |
| Linux    | `keepassxc`       | `keepassxc`           | `HASH4-keepassxc-2.7.12`          |

On Linux, `pkgs.keepassxc` is a trivial `runCommand` symlink drv that only
exists to rebrand pname. Cost: one extra derivation per signed package, ~no
CPU, minimal disk (one symlink).

Pros: consistent naming across platforms; every attr's pname matches the attr
name; existing `-unwrapped` precedent is literal.
Cons: the Linux-side rename drv is pure ceremony.

**Option B — Single pname, attribute aliasing**

| platform | attr              | pname      | store path                  |
|----------|-------------------|------------|-----------------------------|
| Darwin   | `keepassxc-unsigned` | `keepassxc` | `HASH1-keepassxc-2.7.12`    |
| Darwin   | `keepassxc`       | `keepassxc` | `HASH2-keepassxc-2.7.12`    |
| Linux    | `keepassxc-unsigned` | `keepassxc` | `HASH3-keepassxc-2.7.12`    |
| Linux    | `keepassxc`       | `keepassxc` | `HASH3-keepassxc-2.7.12` (alias) |

`pname` is `keepassxc` everywhere. On Linux, the two attributes resolve to the
same store path (literal alias, not a rename wrapper).

Pros: zero ceremony drv; cheaper.
Cons: two distinct Darwin drvs share a pname (hash distinguishes them but
`nix-env -qa` output is ambiguous without attribute context); `nix-store -q`
can't tell unsigned from signed by name alone.

**Option C — Conditional pname**

`pname = if isDarwin then "keepassxc-unsigned" else "keepassxc"` in the
unsigned drv. The unsigned version literally changes name based on platform.

Pros: no rename drv; no ambiguity on Darwin.
Cons: same source builds under different names on different platforms — this
is the weirdest option and likely to confuse tooling that assumes `pname` is
a property of the package, not the platform.

**Recommendation**: Option A. The `-unwrapped` precedent is strong, and the
trivial rename drv on Linux is a one-time cost per package in a shared helper
(`linux-passthrough`). Tooling consistency matters more than one drv per
package.

### How much confusion is this?

Surface areas where users might trip:

1. **`nix-env -qa` output**: on Darwin shows both `keepassxc-2.7.12` and
   `keepassxc-unsigned-2.7.12`. A user searching for "keepassxc" sees two
   hits. They install `keepassxc`. This is fine — `-unwrapped` already
   teaches this pattern.

2. **Override chains**: `keepassxc.override { ... }` goes through the signed
   wrapper and may not propagate as users expect. Convention already says
   "override `keepassxc-unwrapped`, then wrap". We inherit the same idiom.
   Signatures are a function of the unsigned output, so any override that
   changes the unsigned output invalidates committed signatures (build-time
   verification catches this).

3. **`nix why-depends`**: a library that embeds a Mach-O might depend on the
   signed version; tooling and dependency-walking assumes attribute = drv.
   Same as `-unwrapped`.

4. **Cross-platform attr references**: `pkgs.legacyPackages.x86_64-linux.keepassxc`
   and `pkgs.legacyPackages.aarch64-darwin.keepassxc` must both resolve. With
   Option A, they do — each platform's `keepassxc` is whatever is
   appropriate.

No novel confusion surface beyond what `-unwrapped` already teaches. Worth
writing explicit docs for the first signed package.

## 6. Distribution: in-tree vs out-of-tree

### In-tree (signatures live in nixpkgs)

Pros:
- Discoverability: users find signed packages via `nix search nixpkgs`.
- Single source of truth: version + signatures move together in one PR.
- Version skew impossible by construction.

Cons:
- Governance: who holds the Developer ID? Nixpkgs has no legal entity. Any
  signer is a named individual. If they step down, signatures stop flowing.
- Apple's ToS: a Developer ID is issued to a specific person or
  organization. Signatures distributed as "nixpkgs' signatures" could
  misrepresent provenance.
- Commit ACL: every nixpkgs committer can in principle commit signature
  files, but only key-holders can produce valid ones. CI catches invalid
  commits, but the separation of "who can write" from "who can sign" is
  uncomfortable.
- Hydra load: every Darwin signed package becomes a Hydra build. Adding to
  already-scarce Darwin builder time.

### Out-of-tree (separate overlay / flake)

Pros:
- Governance clarity: overlay maintainers are a small set of key-holders.
  ACL matches trust boundary.
- Faster iteration: nixpkgs review cycles don't block signing.
- Can fork / duplicate: multiple overlays can offer different signers'
  provenance. Users opt into whichever trust root they want.
- Scope control: each overlay decides which packages it signs; no pressure
  to cover the full tree.
- Legal clarity: individual signers identify themselves to Apple; the
  overlay documents the identity.

Cons:
- Discoverability: users must know the overlay exists and enable it.
- Version coupling: overlay pins a nixpkgs version; users must align.
- Ecosystem fragmentation risk if many overlays emerge.

### Precedent

- **NUR (Nix User Repository)**: out-of-tree overlays, user-curated, no
  central ACL. Precedent for community packaging outside nixpkgs.
- **home-manager**: lives outside nixpkgs with its own release cadence,
  flake + non-flake distribution. Precedent for substantial infrastructure
  that doesn't fit nixpkgs' governance model.
- **nix-darwin**: same pattern as home-manager.
- **nixos-hardware**: out-of-tree overlays for hardware-specific tweaks.
- **cachix / attic**: out-of-tree artifact distribution with pinning.

No direct precedent for "signatures held by a specific signer, consumed
hermetically by the distribution tree". Closest analog:
**reproducible-builds.org's signatures for Debian**, which live in a separate
repo maintained by the signer, not in Debian proper.

### Recommendation

**Split the artifact from the mechanism.**

- **Merge to nixpkgs**: the `codesign` helper, the `codesign-sign` wrapper,
  the `-unsigned` / `-signatures` / `<name>` convention, docs. These require
  no keys, no signing ceremony; they're plain infrastructure.
- **Don't merge to nixpkgs**: the signatures themselves. Signatures live in
  a separate, opt-in overlay (initially as `github:tnichols/nixpkgs-darwin-signed` or
  similar; eventually community-run).

This gives nixpkgs a `pkgs.<name>-unsigned` drv that is directly usable
(unsigned, works fine for most users) and a `pkgs.codesign` helper that lets
anyone — including downstream overlay maintainers — produce signed variants.
Nixpkgs doesn't take on signing operation; it takes on signing infrastructure.

Signed overlay(s) then implement `pkgs.<name> = codesign { ... } pkgs.<name>-unsigned`
for their curated set.

## 7. Flake vs non-flake

Nixpkgs commits to both. The overlay should also work both ways.

### Flake consumers

```nix
{
  inputs.nixpkgs-darwin-signed.url = "github:tnichols/nixpkgs-darwin-signed";
  inputs.nixpkgs-darwin-signed.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nixpkgs, nixpkgs-darwin-signed, ... }: let
    pkgs = import nixpkgs {
      system = "aarch64-darwin";
      overlays = [ nixpkgs-darwin-signed.overlays.default ];
    };
  in ...
}
```

Pinning via `flake.lock` is automatic. Overlay pins its own nixpkgs
(via `follows` or independent pin); signatures are valid for that pin only.

### Non-flake consumers

```nix
let
  nixpkgs-darwin-signed = import (fetchTarball {
    url = "https://github.com/.../archive/<rev>.tar.gz";
    sha256 = "...";
  }) { };

  pkgs = import <nixpkgs> {
    overlays = [ nixpkgs-darwin-signed.overlay ];
  };
in ...
```

Pinning via user's chosen tool (niv, npins, hand-rolled fetchTarball). Overlay
must expose a non-flake entrypoint (a `default.nix` that returns
`{ overlay, overlays, packages, ... }`). This is the pattern home-manager
and nix-darwin already follow.

The overlay structure:

```
nixpkgs-darwin-signed/
  flake.nix                 # flake entrypoint
  default.nix               # non-flake entrypoint
  overlay.nix               # actual overlay function
  pkgs/
    ke/keepassxc/
      signatures.nix
      sigs/
      entitlements/
      manifest.json
    ...
  lib/
    signing-ceremony.nix    # codesign-sign configuration helpers
```

Does it **need** to be a flake? No. A plain repo with `default.nix` is
sufficient for non-flake consumers. The flake is a convenience layer.

**Recommendation**: support both. Flake as primary; `default.nix` as a
flake-compat shim (trivial — there's a standard pattern).

## 8. Scope: curated vs tree-wide

Blindly signing every Mach-O in nixpkgs Darwin is infeasible:
- 10k+ packages, many producing multiple Mach-Os
- Rebuilds on every stdenv bump invalidate everything
- RFC 3161 rate limits (Apple's TSA: ~1/sec; DigiCert's public TSA: similar) → hours per full re-sign

The overlay should **curate**: focus on packages where Developer ID actually
buys something. Criteria:
- GUI apps that users launch via Finder (Gatekeeper gate)
- Apps that request TCC-protected resources (Developer ID improves UX)
- Apps that need specific entitlements (Keychain access groups, JIT, etc.)
- Apps that integrate with notarization infrastructure

Rough initial scope (illustrative, ~10-30 packages):
- keepassxc, anki, audacity, discord, signal-desktop, obs-studio, spotify,
  vlc, kitty, wezterm, alacritty, iterm2 (if packaged), utm, etc.

CLI tools, libraries, compilers, headless servers: leave ad-hoc signed. They
already work.

## 9. Build-time verification

Three layers:

### Layer 1: eval-time check (cheap, in `codesign` helper)

`signatures.passthru.unsignedDrvOutputHash` compared to
`unsigned.outPath` (or hash derived from it). Implemented as a Nix `assert`
so `nix-instantiate` / `nix flake check` fails fast. No building required.

```nix
assert signatures.passthru.unsignedDrvOutputHash == unsigned.outPath;
```

### Layer 2: splicer verification (at build time)

For each Mach-O spliced:
- Recompute the Mach-O's CodeDirectory hash after splicing
- Compare to the cdhash embedded in the detached signature (sanity: the CMS
  blob signs that same CD, so if cdhashes agree, the CMS is valid for this
  Mach-O)
- Recompute `CodeResources` content hash and compare to the committed copy
- If on Darwin: `codesign --verify --deep --strict --verbose=4 $out` as a
  final check

### Layer 3: periodic CI sweep (at project level)

Cron job on signing overlay's CI: for each signed pkg, eval
`unsigned.outPath` against `manifest.unsignedDrvOutputHash`. List
mismatches. Notify maintainer. This catches silent drift after a nixpkgs
rebase that invalidates hashes.

## 10. Hydra / CI

### Nixpkgs-side (infrastructure only)

No new jobsets required. The `codesign` helper, `codesign-sign` wrapper, and
`-unsigned` conventions are plain derivations. Existing Darwin jobsets build
them.

### Overlay-side

Needs its own CI, because Hydra won't build an out-of-tree overlay.
Realistic:
- GitHub Actions with Darwin runners for build + verify
- Schedule: on-push + daily cron (to detect nixpkgs-rebase drift)
- Artifacts: optional binary cache (cachix / attic) for prebuilt signed
  outputs, so downstream consumers don't rebuild

Scale: for a curated 30-package overlay, a Darwin runner can cover the full
set in an hour or two. Feasible.

If the overlay grows significantly, a dedicated Hydra instance or mirror
makes sense. Not v1.

## 11. Atomicity and tree-wide changes

### Per-PR atomicity

A PR that bumps `<name>-unsigned` must include new signatures. The eval-time
check enforces this: PRs that only bump the unsigned side fail CI with a
hash mismatch.

### Tree-wide ripples

A change to a shared dep (qtbase, openssl, icu) invalidates all transitive
unsigned outputs. The overlay handles this with a batch re-sign script:

```
just resign-all --nixpkgs-rev <rev>
```

The script:
1. Pins nixpkgs to `<rev>`
2. For each signed package: build unsigned, re-sign, commit
3. Opens a PR with the updated signatures

This runs on a signer's workstation (key required) or a self-hosted runner
with access to the key (HSM, keychain, or sops-encrypted p12).

TSA rate limits cap throughput. For 30 packages × ~5 Mach-Os avg × 1
TSA-request/sec, full re-sign is ~150 seconds of TSA time. Bundle + verify
overhead is more — estimate 30 minutes wall-clock for 30-package re-sign.

### Do we need two versions?

No. Version skew is resolved by the overlay pinning a specific nixpkgs
revision. If the overlay has signatures for `keepassxc 2.7.12` built
against nixpkgs-rev-X, and nixpkgs moves to 2.8.0, the overlay's `keepassxc`
is 2.7.12 against pinned-rev-X until the signer catches up. Users who want
2.8.0 immediately can use the unsigned drv from current nixpkgs.

Maintaining dual versions in-tree (e.g., `keepassxc_signed` +
`keepassxc_latest`) doubles derivation count for no benefit; overlays
already provide temporal pinning.

## 12. ACL and governance

### Nixpkgs side

- Committers: any nixpkgs committer can modify the `codesign` helper,
  `codesign-sign` wrapper, `-unsigned` drv, etc.
- No keys involved; no signing responsibility; no governance change from
  status quo.

### Overlay side

- Maintainers: small set (initially one; grow cautiously).
- Write access: only maintainers. Strict.
- Signatures produced by which Developer IDs: documented in the overlay's
  `SIGNERS.md`. Each sig's CMS blob names the signer; users can audit.
- Trust model: users who subscribe to the overlay implicitly trust the
  signer not to sign malicious binaries. Same as trusting any package
  maintainer, with the extra step that signatures make the trust
  cryptographically provable.
- Revocation: if a signer's Developer ID is revoked, users need to pull an
  overlay update that ships new signatures from a replacement signer. No
  in-band revocation mechanism (Apple's OCSP handles cert revocation at
  verify time, but doesn't push new signatures).

### Multiple overlays

Eventually healthy: different signers, different scopes, different trust
roots. Users opt into the one(s) they trust. Community infrastructure (a
registry, a meta-overlay) can emerge organically.

## 13. Open questions

- **Notarization**: a Developer ID signature is necessary but not sufficient
  for Gatekeeper-quiet launch. Notarization adds a staple to the bundle.
  Should the overlay also ship stapled notarization tickets? Probably yes,
  same mechanism (committed data file, spliced at build).
- **Hardened runtime**: most Developer ID-signed apps want `--options
  runtime`. Should this be the default in `codesign-sign`? Probably yes.
- **Framework/XPC nesting**: the splicer must handle nested bundles
  (`.framework`, `.appex`, `.xpc`) with their own CodeResources. Not in v1
  scope; initial packages are picked to avoid this until the primitives are
  solid.
- **Universal binaries**: nixpkgs doesn't produce fat Mach-Os today. If that
  changes, detached sigs are already arch-keyed; the splicer handles it
  natively.
- **Revocation / key rotation**: what happens when a Developer ID expires?
  RFC 3161 timestamps keep already-signed binaries valid, but new signatures
  need a new key. Overlay migration story.
- **Public-key-only verification path**: a future refinement could let nix
  evaluate signatures with the signer's public key only (no Apple
  network), enabling provenance checks in fully offline Hydra builders.
  Not v1.

## 14. Roadmap

### Phase 1: prototype (this dotfiles repo)

- [ ] Rust splicer tool: read detached sig, splice into Mach-O, resize `__LINKEDIT`
- [ ] `codesign` Nix helper wrapping the splicer; drop-in for `modules/home/keepassxc`
- [ ] `codesign-sign` signing ceremony (fish/just recipe initially, Rust later)
- [ ] Signatures committed under `modules/home/keepassxc/signatures/`
- [ ] KeePassXC working end-to-end signed + hermetic in this config

### Phase 2: second package (validate generality)

- [ ] Pick a package with different shape (e.g., Anki: large bundle with many
      nested Mach-Os but no plugins; or Audacity: plugins-heavy)
- [ ] Confirm `codesign` helper handles nested bundles and frameworks
- [ ] Extract the tooling out of `modules/home/<pkg>/` into a shared flake

### Phase 3: overlay

- [ ] Split tooling into `codesign-nixpkgs` (helper + wrapper, language-crate layout)
- [ ] Create `nixpkgs-darwin-signed` overlay with 3-5 curated packages
- [ ] Flake + non-flake entrypoints
- [ ] CI: GitHub Actions with Darwin runner, nightly verify against nixpkgs HEAD
- [ ] Optional: binary cache for prebuilt signed outputs

### Phase 4: upstream proposal

- [ ] RFC in nixpkgs repo proposing `pkgs.codesign` + `pkgs.codesign-sign` +
      the `-unsigned` / `-signatures` / `<name>` triple convention
- [ ] Reference implementation PR
- [ ] Docs + one real package conversion (e.g., KeePassXC's Darwin build adopts
      `-unsigned` and publishes a `passthru.signable = true` hint)
- [ ] Announce the reference overlay as the consumer

### Phase 5: sustain

- [ ] Notarization ticket stapling
- [ ] Additional signer(s) / trust-root diversity
- [ ] Community adoption path

## 15. References

### Apple official documentation

- Apple Platform Security (landing):
  https://support.apple.com/guide/security/welcome/web —
  Apple's consolidated security documentation. The
  [PDF mirror](https://help.apple.com/pdf/security/en_US/apple-platform-security-guide.pdf)
  is useful for stable citations since the HTML reorganizes periodically.
- <a id="aps-code-signing"></a>**App code signing process**:
  https://support.apple.com/guide/security/app-code-signing-process-sec7c917bf14/web —
  canonical overview of the signature's structure and role.
- <a id="aps-gatekeeper"></a>**Gatekeeper and runtime protection**:
  https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web —
  "[The] notarization pipeline [is] designed to ensure that apps contain no
  known malware." Gatekeeper verifies software is "from an identified
  developer, is notarized by Apple to be free of known malicious content,
  and hasn't been altered."
- <a id="aps-malware"></a>**Protecting against malware in macOS**:
  https://support.apple.com/guide/security/protecting-against-malware-sec469d47bd8/web —
  describes revocation of Developer ID certs and notarization tickets as
  the remediation path for discovered malware.
- <a id="apple-identity-verification"></a>**Developer Program identity
  verification**:
  https://developer.apple.com/help/account/membership/identity-verification —
  scope of identity verification at cert issuance time (legal name, D-U-N-S
  for orgs, binding authority check).
- **Create Developer ID certificates**:
  https://developer.apple.com/help/account/create-certificates/create-developer-id-certificates/ —
  Apple's description of what the Developer ID cert signals to Gatekeeper.
- <a id="tn2206"></a>**Technical Note TN2206: macOS Code Signing In Depth**:
  https://developer.apple.com/library/archive/technotes/tn2206/_index.html —
  the technical reference for the signature format and the code requirement
  language.
- <a id="apple-hardened"></a>**Hardened Runtime**:
  https://developer.apple.com/documentation/security/hardened-runtime
- <a id="apple-entitlements"></a>**Entitlements**:
  https://developer.apple.com/documentation/bundleresources/entitlements
- <a id="apple-keychain-sharing"></a>**Sharing access to keychain items
  among a collection of apps**:
  https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps

### Independent technical analysis

- <a id="oakley-arm64"></a>Oakley, H. (2020). **"Apple Silicon Macs will
  require signed code"**: https://eclecticlight.co/2020/08/22/apple-silicon-macs-will-require-signed-code/ —
  primary readable source on the arm64 linker-signed-or-execution-denied
  policy. Derived from WWDC 2020 session 10686.
- <a id="oakley-notarization"></a>Oakley, H. (2020). **"How notarization
  works"**: https://eclecticlight.co/2020/08/28/how-notarization-works/ —
  describes the notarization pipeline in practical detail.
- <a id="oakley-tcc"></a>Oakley, H. (2019). **"Code signing for the
  concerned, part 5: signing and privacy control"**:
  https://eclecticlight.co/2019/01/29/code-signing-for-the-concerned-5-signing-and-privacy-control/ —
  documents how TCC tracks apps by signature rather than cdhash, so grants
  survive Developer ID-signed updates.
- Oakley, H. (2024). **"Gatekeeper and notarization in Sequoia"**:
  https://eclecticlight.co/2024/08/10/gatekeeper-and-notarization-in-sequoia/ —
  current Gatekeeper tier behavior, including Sequoia tightening around
  Developer-ID-without-notarization.
- <a id="wardle-approved-malware"></a>Wardle, P. (2020). **"Apple Approved
  Malware"**: https://objective-see.org/blog/blog_0x4E.html —
  empirical evidence that notarization does not constitute a security
  audit.

### Reproducible builds ecosystem

- <a id="rb-org"></a>**Reproducible Builds** (landing):
  https://reproducible-builds.org/ — "a set of software development
  practices that create an independently-verifiable path from source to
  binary code."
- **Sharing certifications**:
  https://reproducible-builds.org/docs/sharing-certifications/ — model for
  multiple parties attesting to a single build output, analogous to the
  multi-signer case of this proposal.
- <a id="debian-rb"></a>**Debian Reproducible Builds**:
  https://wiki.debian.org/ReproducibleBuilds/About — Debian's articulation
  of provenance attestation: "independent verifications that a binary
  matches what the source intended to produce."

### Standards

- <a id="rfc3161"></a>**IETF RFC 3161**: Internet X.509 PKI Time-Stamp
  Protocol (TSP): https://datatracker.ietf.org/doc/html/rfc3161 — the
  standard used by Apple's TSA and DigiCert's public TSA.

### Implementation references

- **`apple-codesign`** (Rust crate, also ships as `rcodesign` CLI):
  https://crates.io/crates/apple-codesign — cross-platform, offline
  codesigning implementation. Primary toolkit for the splicer.
- **Apple Security framework source**: `CSCommon.h` (code signing
  constants and magic numbers) at
  https://opensource.apple.com/source/Security/ — authoritative definitions
  for `CSMAGIC_EMBEDDED_SIGNATURE` (`0xfade0cc0`),
  `CSMAGIC_DETACHED_SIGNATURE` (`0xfade0cc1`), and related blob types.

### Nixpkgs conventions

- `-unwrapped` convention: see
  `pkgs/applications/networking/browsers/firefox/` in nixpkgs — the canonical
  precedent for a two-derivation user-facing-vs-internal split.
- [home-manager](https://github.com/nix-community/home-manager) — precedent
  for substantial out-of-tree Nix infrastructure shipping both flake and
  non-flake entrypoints.
- [Nix User Repository (NUR)](https://github.com/nix-community/NUR) —
  precedent for community-maintained overlays outside nixpkgs.

### Gaps

The following claims lack a single strong citation and are synthesized
across sources:

- The clean three-tier Gatekeeper behavior table is not laid out in one
  Apple document. Synthesize Apple Platform Security + Oakley's Sequoia
  article.
- Per-entitlement documentation pages (`com.apple.security.cs.*`) render
  heavily with JavaScript and are easier to evaluate in a browser than to
  excerpt. Entry points:
  https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_cs_allow-jit
  and https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_cs_disable-library-validation .
- Arm64 kernel-level signing enforcement is stated definitively only at
  WWDC 2020 session 10686 (video). Oakley's article is the best citable
  secondary source.

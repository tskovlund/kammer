# BUILDLOG

Session journal and decision record for the Kammer Phase 1 build (SPEC.md §16).
Every scope trim, stub, deferral, or library substitution is recorded here —
silent stubs are forbidden by the one-shot build rule (SPEC.md §16).

Format: newest entries at the bottom. Each entry: date, what was done/decided,
why, and (for trims) precisely how to complete the cut work.

---

## 2026-07-06 — Session start, environment bring-up

**State**: empty repository, branch `claude/kammer-phase-1-g0wnzc`.

**Build container**: Ubuntu 24.04, no Nix/Elixir preinstalled. Installed
Determinate Nix 3.21.1 (Nix 2.34.7) with `--init none` (no systemd in
container); `nix-daemon` started manually in the background. Verified binary
cache fetch + build work through the outbound proxy. PostgreSQL 16 runs
locally in the container for dev/test (the flake provides the client; CI and
compose provide their own server).

**Decision — flake is canonical** (SPEC §14): `flake.nix` defines the dev
toolset; `.envrc` (`use flake`) and `devbox.json` wrap the same set. CI enters
the environment with `nix develop --command` so the toolchain in CI is
byte-identical to local dev.

**Decision — toolchain pin**: Elixir 1.18 on Erlang/OTP 27 from a pinned
nixpkgs-unstable revision (flake.lock). Boring, current stable pair; Phoenix
1.8 supports both. devbox.json pins the same major versions via the devbox
package index.

**Decision — nixpkgs pinned via releases.nixos.org tarball, not `github:`**:
this build container's egress proxy blocks GitHub fetches outside the session
repo scope, so `github:NixOS/nixpkgs/...` flake inputs cannot be fetched here.
The flake instead pins the immutable channel-release tarball
`https://releases.nixos.org/nixpkgs/nixpkgs-26.11pre1027958.c4013e501c04/nixexprs.tar.xz`
(locked with narHash in flake.lock). This is equally reproducible — the URL is
versioned and immutable — and avoids the GitHub API rate limit for anonymous
users as a bonus. `flake-utils` was dropped (hand-rolled `forAllSystems`) to
keep the input set to exactly one. If a maintainer prefers `github:` inputs
later, swap the URL and re-lock; nothing else changes.

**Verified** (inside `nix develop`): Elixir 1.18.4 (OTP 27), Mix 1.18.4,
Node v22.23.1, psql 16.14, vips 8.18.3, lefthook 2.1.5.

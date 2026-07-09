# 0025 — Versioning model and repository topology

Date: 2026-07-09
Status: accepted (owner-ratified, issue #203)

## Context

The product is becoming multi-artifact: a Phoenix server that ships the
Svelte PWA inside its own Docker image (ADR 0024, #176), future native
Android/iOS apps as API siblings (ADR 0012/0022, #131), and a landing
site (#188). Each artifact needs a versioning rule, and the code needs
a home per artifact. Conflating the axes — one version for everything,
or per-component versions with no compatibility contract — is the
classic failure mode.

## Decision

**Versioning has three independent axes:**

1. **API contract version** (`/api/v1`) — the only compatibility
   boundary clients and server must agree on. It bumps rarely and
   deliberately: a breaking contract change means a new `/api/v2`,
   gated by an ADR. Additive change never bumps it.
2. **Server + PWA: lockstep, one SemVer, git-tagged.** The PWA is
   built into and served from the instance's image, so server and web
   client are one deployable artifact with no skew to manage — one
   version, one tag, one CHANGELOG (the Ghost/Discourse model).
   `v0.1.0` names this pair. Pre-1.0 stays `0.x`, where SemVer permits
   breaking changes between minors.
3. **Native apps: each its own SemVer and store cadence.** Installed
   apps cannot be lockstepped to server deploys; they negotiate purely
   through the API version plus a minimum-server-version handshake —
   the instance advertises `version`, `api_versions`, and
   `min_client_version` at a public meta endpoint (#204); mismatch
   surfaces as "update your instance / update the app".

**Repository topology: modular monorepo plus satellite native repos.**

- `kammer` (this repo): backend + PWA (`clients/web`) + landing
  (`site/`, Pages-deployed). Backend and PWA ship together and every
  parity-ladder rung touches both; splitting them would force
  cross-repo coordination on nearly every change. The landing site is
  low-churn and reuses the screenshot pipeline (#189) and §21 design;
  it graduates to its own repo only if it grows past that.
- `kammer-android`, `kammer-ios`: separate repos. Distinct toolchains
  (Gradle / Xcode + macOS CI), release trains (Play / App Store), and
  contributor skillsets. They consume the published OpenAPI document
  as external clients — the contract is the spec, so no shared-code
  repo exists to drift.
- A GitHub organization becomes the home for all of them; the transfer
  of this repo is sequenced by the owner (issue #203) because agent
  access must be re-authorized at the new location — an org move mid
  autonomous-stretch would sever the build.

## Consequences

- Release engineering stays simple until native apps exist: tag the
  repo, the image is the release, the CHANGELOG is its notes.
- The meta endpoint (#204) must exist before any native client ships,
  and `min_client_version` gives instances a lever to force app
  updates without breaking the API contract.
- A breaking API change is expensive by design (new version namespace,
  ADR, migration window for native apps) — pressure stays on additive
  evolution, which is the right default for self-hosted instances that
  upgrade at their own pace.
- The naming decision (#209) may rename artifacts and domains; nothing
  in this ADR depends on the name.

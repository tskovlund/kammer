# Releasing Kammer

Releases are tag-driven and automated; the human part is deciding what
ships and writing the changelog. Releases are **immutable** (repo
setting): a published release and its tag can never be altered — if a
release is bad, ship a fix-forward patch release, never re-tag.

## The process

1. **Curate the changelog.** Move the relevant `## [Unreleased]`
   entries in `CHANGELOG.md` under a new `## [X.Y.Z] - YYYY-MM-DD`
   heading ([Keep a Changelog](https://keepachangelog.com) format —
   the release notes are extracted from exactly this section).
2. **Bump the version** in `mix.exs` (`version: "X.Y.Z"`). The release
   workflow refuses tags that don't match it.
3. **PR and merge** those two changes to `main` (required checks
   apply, like any change).
4. **Tag the merge commit:**

   ```sh
   git tag vX.Y.Z <merge-sha>   # or on up-to-date main: git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

5. **Automation takes over.** Two workflows fire on the tag:
   - `release.yml` verifies tag ↔ `mix.exs` agreement, extracts the
     `[X.Y.Z]` CHANGELOG section, and publishes the GitHub Release
     with those notes (plus the container-image reference).
   - `docker.yml` builds and pushes `ghcr.io/tskovlund/kammer:X.Y.Z`.

6. **Verify:** the Releases page shows the notes; the image tag exists
   under Packages. Deployments pin the version tag, so nothing updates
   itself until an operator chooses to.

## Versioning

SemVer, pre-1.0 semantics: `0.MINOR` may break, `0.x.PATCH` must not.
`1.0.0` when a real community runs on it through a full season without
schema surgery.

## If a release is bad

Do **not** delete or re-tag (immutability blocks it, deliberately).
Fix on `main`, cut `vX.Y.(Z+1)`, and note the supersession in the new
changelog section.

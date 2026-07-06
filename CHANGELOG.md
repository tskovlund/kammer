# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Reproducible dev environment: Nix flake (canonical), direnv `.envrc`,
  `devbox.json` — one toolset, three entry paths, reused by CI.
- Phoenix 1.8 application scaffold (LiveView, Tailwind, UUID primary keys).
- Engineering-standards toolchain: mix format, Credo strict (incl. custom
  single-letter-variable ban), Dialyzer, Sobelow, ExCoveralls with coverage
  floor, mix_audit/hex.audit, lefthook hooks, commitlint, GitHub Actions CI,
  warnings-as-errors.

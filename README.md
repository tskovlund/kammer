# Kammer

[![CI](https://github.com/tskovlund/kammer/actions/workflows/ci.yml/badge.svg)](https://github.com/tskovlund/kammer/actions/workflows/ci.yml)
[![Docker](https://github.com/tskovlund/kammer/actions/workflows/docker.yml/badge.svg)](https://github.com/tskovlund/kammer/actions/workflows/docker.yml)
[![CodeQL](https://github.com/tskovlund/kammer/actions/workflows/codeql.yml/badge.svg)](https://github.com/tskovlund/kammer/actions/workflows/codeql.yml)
[![License](https://img.shields.io/github/license/tskovlund/kammer)](LICENSE)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-fe5196?logo=conventionalcommits&logoColor=white)](https://www.conventionalcommits.org)
[![Renovate](https://img.shields.io/badge/renovate-enabled-brightgreen?logo=renovate)](https://github.com/tskovlund/.github/blob/main/default.json)

**A calm, self-hosted home for real-world communities.**

Kammer replaces Facebook Groups/Pages/Events, the group email thread, and the
file-sharing half of Google Drive — for associations, bands, clubs, and every
other community that exists first in the real world and only second on a
screen.

<p align="center">
  <img src="docs/screenshots/feed-desktop.png" alt="A group feed in Kammer: Markdown posts, reactions, comments, and a composer with polls, scheduling, and acknowledgment-required posts" width="800">
</p>
<p align="center">
  <img src="docs/screenshots/feed-mobile.png" alt="The mobile feed with bottom tab navigation" width="189">
  <img src="docs/screenshots/feed-desktop-dark.png" alt="The same feed in dark mode" width="399">
  <img src="docs/screenshots/event-desktop.png" alt="An event page with RSVP" width="399">
</p>

<sub>Screenshots are generated from a real instance by `scripts/screenshots.sh` and regenerated when the UI changes.</sub>

## Why Kammer

- **No ads. No algorithm. Ever.** Feeds are strictly chronological plus
  pinned posts. What your community posts is what your community sees.
- **Privacy-first.** No tracking, no analytics, no phone-home. Honest about
  limits: we tell you exactly what the server operator can and cannot see.
- **A joy to self-host.** One `docker compose up`, a first-run wizard, and a
  reproducible Nix-defined dev environment for contributors. Built-in backups
  and guest interactions (RSVP and comments without an account) are on the
  roadmap (SPEC.md §16, Phase 2).
- **Institutional memory is the product.** Groups archive instead of
  vanishing; files stay browsable; seasonal bands and committees keep their
  history.

## Features (Phase 1)

- **Passwordless sign-in** — magic links; passkeys on the roadmap.
- **Communities and groups** — one instance hosts many communities; four
  visibility presets (`private`, `community`, `public_link`, `public_listed`),
  join/posting/comment policies, invite links, roles, and **sealed groups**
  that even community admins cannot open.
- **Feed** — Markdown posts, images (re-encoded with metadata stripped,
  thumbnailed), polls, file attachments, emoji reactions, single-level
  comment threads, mentions, pinned + scheduled + acknowledgment-required
  posts, live updates.
- **Events** — timezone-aware, all-day/multi-day, RSVP, comments, email
  reminders, ICS calendar feeds.
- **Files** — community and group spaces, shallow folders, preset-based
  permissions with a centrally enforced visibility invariant, quotas if you
  want them.
- **Notifications** — in-app center, email, and Web Push with sane
  "highlights" defaults.
- **English + Danish** throughout, including emails.

## Quickstart (self-hosting)

```sh
git clone https://github.com/tskovlund/kammer.git
cd kammer
cp .env.example .env      # edit: PHX_HOST, SECRET_KEY_BASE, POSTGRES_PASSWORD, SMTP_*
docker compose up -d
```

Then open your instance URL and follow the first-run wizard — the setup
token is printed in the server logs (`docker compose logs app`). The wizard
creates your operator account, instance settings, first community and group,
an invite link, and (optionally) a removable demo community. Health checks
live at `/healthz`; put a TLS proxy in front (see
`docs/deploy/Caddyfile.example`).

## Documentation

| Document                                             | What it covers                                             |
| ---------------------------------------------------- | ---------------------------------------------------------- |
| [Development](docs/development.md)                   | Workflow, everyday commands, what the automation does      |
| [Releasing](docs/release.md)                         | Tag-driven releases, versioning, immutability              |
| [Deployment](docs/deploy/)                           | Reverse-proxy example; `.env.example` documents all config |
| [Architecture decisions](docs/decisions/)            | Twelve ADRs — the "why" behind the shape of the system     |
| [GitHub configuration](docs/github/repo-settings.md) | Repo automation and the one-time admin settings            |
| [SPEC.md](SPEC.md) / [BUILDLOG.md](BUILDLOG.md)      | The product spec and the build journal                     |

## Contributing

The dev environment is defined once (Nix flake) with three entry paths:

```sh
direnv allow    # or: devbox shell    # or: nix develop
mix setup && mix phx.server
```

See [CONTRIBUTING.md](CONTRIBUTING.md) and [CONVENTIONS.md](CONVENTIONS.md).
Engineering standards (Credo strict, Dialyzer, warnings-as-errors, coverage
floor, Conventional Commits) are enforced by hooks and CI.

## Honest limitations

- **The server operator can technically read the database.** "Sealed" groups
  hide content from community admins — not from whoever runs the server.
  There is no end-to-end encryption.
- No chat/DMs, no video upload, no document editing in v1 — see SPEC.md §16
  for the roadmap and deliberate non-goals.
- Upload hardening (image re-encoding, metadata stripping, content-type
  validation, forced downloads for non-images) is always on; antivirus
  scanning is not built in.

## Author

Thomas Skovlund Hansen — [skovlund.dev](https://skovlund.dev) · [thomas@skovlund.dev](mailto:thomas@skovlund.dev)

## License

[AGPLv3](LICENSE). If you run a modified Kammer for others, you share your
changes. That's the deal.

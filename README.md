# Kammer

**A calm, self-hosted home for real-world communities.**

Kammer replaces Facebook Groups/Pages/Events, the group email thread, and the
file-sharing half of Google Drive — for associations, bands, clubs, and every
other community that exists first in the real world and only second on a
screen.

Built for and battle-tested with TÅGEKAMMERET, a Danish student association,
and its 70-year anniversary revy band.

## Why Kammer

- **No ads. No algorithm. Ever.** Feeds are strictly chronological plus
  pinned posts. What your community posts is what your community sees.
- **Privacy-first.** No tracking, no analytics, no phone-home (the optional
  release check is admin-only and toggleable). Honest about limits: we tell
  you exactly what the server operator can and cannot see.
- **Frictionless for non-members.** Guests RSVP to events, subscribe to
  public feeds by email, and comment (approval-queued) with nothing but an
  email address — no account, no app install.
- **A joy to self-host.** One `docker-compose up`, a first-run wizard, built-in
  backups, and a reproducible Nix-defined dev environment for contributors.
- **Institutional memory is the product.** Groups archive instead of
  vanishing; files stay browsable; seasonal bands and committees keep their
  history.

## Features (Phase 1)

- **Passwordless sign-in** — magic links; passkeys on the roadmap.
- **Communities and groups** — one instance hosts many communities; four
  visibility presets (`private`, `community`, `public_link`, `public_listed`),
  join/posting/comment policies, invite links, roles, and **sealed groups**
  that even community admins cannot open.
- **Feed** — Markdown posts, images (EXIF-stripped, HEIC-converted,
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
cp .env.example .env      # edit: domain, SMTP
docker compose up -d
```

Then open your instance URL and follow the first-run wizard (the setup token
is printed in the server logs). Ten minutes from zero to an invited,
posting community — see `docs/` for the full tutorial.

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
- Antivirus scanning of uploads (optional ClamAV) is signature-based and
  imperfect; upload hardening (re-encoding, content-type validation) is
  always on.

## License

[AGPLv3](LICENSE). If you run a modified Kammer for others, you share your
changes. That's the deal.

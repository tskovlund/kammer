# Security Policy

Kammer is a privacy-first, self-hosted community platform. Security reports
are taken seriously and handled with priority.

## Supported versions

Until 1.0, only the latest release (and the `main` branch) receive security
fixes.

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Instead, report privately via GitHub Security Advisories
("Report a vulnerability" on the repository's Security tab).

Include, where possible:

- A description of the vulnerability and its impact
- Steps to reproduce (proof of concept welcome)
- Affected version/commit and configuration (storage adapter, reverse proxy, …)

## What to expect

- **Acknowledgment** within 72 hours.
- **Assessment and triage** within 7 days: severity, affected versions,
  remediation plan.
- **Fix and disclosure**: we aim to ship fixes for high-severity issues within
  30 days. We coordinate disclosure timing with the reporter and credit
  reporters in the release notes unless they prefer otherwise.

## Scope notes for self-hosters

- The server operator can always technically read the database — this is
  documented product behavior (see SPEC.md §3), not a vulnerability. "Sealed"
  groups protect against *community admins*, not against the instance operator.
- Reports about missing rate limits, guest-link token weaknesses, upload
  hardening bypasses (content-type spoofing, SVG payloads, EXIF leakage), and
  authorization/visibility violations are all firmly in scope and especially
  welcome.

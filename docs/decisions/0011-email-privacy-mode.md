# ADR 0011: Content-minimized email mode

## Context

Email is the least private channel Kammer uses: it transits and rests on
third-party servers. Some communities (and some jurisdictions' expectations)
warrant keeping content out of inboxes entirely.

## Decision

An instance-level toggle switches notification emails to **content-minimized
mode**: no post content, only "N new posts in {group}" plus a link.
Auth and RSVP emails are exempt — they are inherently minimal.

## Consequences

- One email-rendering decision point; templates branch on the instance flag.
- Digest emails in minimized mode are counts and links only.
- Default is off (full content), because most communities prefer utility;
  the toggle is documented in the privacy explanation.

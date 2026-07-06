# ADR 0003: Email + magic link as the identity primitive

## Context

Community members range from students to retirees; passwords are the top
support burden and security hole. Guests (event RSVPs, newsletter
subscribers, guest commenters) must participate with zero friction.

## Decision

**Passwordless only.** Email is the universal identity primitive: magic links
(single-use, short-lived, rate-limited) sign users in; passkeys (WebAuthn)
can be registered after first login. Guest interactions are email-only
identities; signing in with that email later upgrades to a full account and
claims guest history automatically.

## Consequences

- Working outbound email is a hard deployment requirement (the setup wizard's
  first magic link doubles as the SMTP test).
- No password storage, reset flows, or complexity rules — ever.
- Account security scales with the user's mailbox security until they add a
  passkey; the threat model documents this honestly.
- v3 may add instance-as-OIDC-provider for cross-instance single accounts;
  AT Protocol/DIDs stay on the watchlist (SPEC §16).

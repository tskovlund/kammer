# ADR 0013: Email-only guest identities with signed-link lifecycle

## Context

Guest RSVP (SPEC §6) is the adoption wedge: a concert invite must work
for people who will never create an account. Guests need identity
(who's coming), verification (no RSVPing as someone else's inbox),
GDPR-grade erasure (SPEC §12), and a promotion path when they finally
register. Sessions, passwords, or accounts-lite would each drag in the
full account machinery for people who explicitly don't want it.

## Decision

A guest is a `guest_identities` row: email (unique, the whole
identity), display name, `verified_at`. Everything else is links:

- **Nothing is recorded until a signed confirm link, sent to the
  address, is followed** — following it is the verification.
- The confirmation email carries the ICS file and a **signed
  management link** — the guest's only credential — which changes the
  answer or **erases the identity and, by cascade, everything it
  authored**.
- Records reference identities via nullable FKs beside the user FK,
  with a database check that exactly one is set.
- Signing in with the guest's email **claims the history**: rows move
  to the account (member records win collisions) and the guest
  identity disappears (SPEC §2).
- Guest permission questions live in `Kammer.Authorization` like all
  others (`can_guest_rsvp?/1`: public presets only, never archived).

## Consequences

- Guests hold no session and touch no auth tables; the token _is_ the
  credential, stateless and expiring (SPEC §11), so there is nothing
  to revoke server-side — expiry and erasure cover the lifecycle.
- The same identity table serves upcoming guest features (approved
  guest comments, newsletter subscriptions) without schema changes to
  their subjects beyond the nullable FK + check pattern.
- Rate limits on guest endpoints reuse the magic-link budgets — both
  are "type an email, cause an email" surfaces.

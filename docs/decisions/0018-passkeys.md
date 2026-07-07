# ADR 0018: Passkeys via Wax, usernameless sign-in, credential-id as the lookup key

## Context

ADR 0003 already decided passkeys register after first magic-link
login. SPEC §16 names **Wax** as the library. What remained: which
Hex package, how registration/authentication round-trip through a
LiveView-heavy, controller-finalized login flow, and how a credential
maps to a user without asking for an email first.

## Decision

**Library**: `wax_` (Hex name — `wax` was taken), a protocol-only
FIDO2/WebAuthn verifier with no UI opinions, matching this codebase's
pattern of hand-rolled minimal LiveView UI over component libraries.

**Flow split — JSON options endpoints, form-POST finalization**:
registration and authentication each get a small controller action
that generates a `Wax.Challenge`, stores it in the plug session, and
returns it as JSON for the client's `navigator.credentials` call. A
colocated JS hook drives the WebAuthn ceremony, then:

- **Registration** (already authenticated, no session change needed):
  the hook `pushEvent`s the attestation back into the LiveView, which
  calls the context function directly and re-renders the passkey list.
- **Authentication** (not yet authenticated, session must change): the
  hook `pushEvent`s the assertion into the `UserLive.Login` LiveView,
  which fills a hidden form and flips `phx-trigger-action` — a real
  browser POST to `UserSessionController`, identical to the existing
  magic-link confirmation pattern, so `UserAuth.log_in_user/3` and its
  redirect/cookie handling need no special-casing for passkeys.

**Usernameless sign-in**: the authentication challenge omits
`allow_credentials` (resident/discoverable credentials only — a real
"passkey", not a bound security key), so the browser prompts for any
saved credential without an email step first. The returned credential
id is looked up directly; `user_passkeys.credential_id` is therefore
**unique instance-wide**, not scoped to a user — we don't know the
user until we've found their credential.

**Storage**: the COSE public key Wax returns is stored via
`:erlang.term_to_binary/1` into an opaque `public_key_cose` binary
column — internal-only, written and read by the same code, never
crosses a trust boundary, so no JSON/CBOR re-encoding scheme is
needed. `sign_count` is compared on each authentication (clone
detection per WebAuthn §7.2) but tolerated at a standing `0` — most
platform authenticators (synced passkeys) never increment it.

**UI**: passkeys live on the existing Devices page (sudo-mode gated),
not a separate page.

## Consequences

- Registration and login share zero controller code but both terminate
  in code that already existed (`UserAuth.log_in_user/3`, the devices
  list) — no parallel session-management path to keep in sync.
- No attestation trust chain is verified (`attestation: "none"`,
  Wax's default) — appropriate for consumer passkeys where the
  authenticator's make/model is not part of the threat model.
- Losing every passkey still leaves magic-link sign-in as the fallback
  — passwordless, not passkey-only.

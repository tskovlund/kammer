# ADR 0029: Step-up re-auth before credential changes, recorded on the device-token row

## Context

The PWA port of passkey enrollment (#260 port 5b) shipped without the
sudo-mode gate the LiveView surface had, on the reasoning that "the
API has no recent-re-auth concept" — recorded as an open call in
issue #294 and a note on ADR 0018. The gap it left: most API actions
can't escalate beyond what a stolen device token already grants, but
a few *outlive or sever* that credential — adding a passkey creates a
login credential that survives device-token revocation, revoking a
different device is how a thief locks the owner out, and changing the
account email redirects every future magic link (the root credential
in a passwordless model). The owner decided option B on #294: build
the step-up properly, as the v1 security bar.

## Decision

**The step-up state lives on the calling device-token row**: a
`stepped_up_at` timestamp on `users_tokens`, fresh for
`STEP_UP_VALIDITY_MINUTES` (tier-2 config, ADR 0027; default 10,
bounds 1–60). No new bearer credential is minted — the elevation is a
property of the credential that asked, dies with it, and cannot be
replayed onto another device. This mirrors how sudo-mode rode
`authenticated_at` on the session, translated to the API's model.

**Two step-up methods**, both re-asserting a root of trust
(`KammerWeb.Api.StepUpController`):

- **Passkey assertion** (`POST /auth/step-up/passkey/challenge` +
  `/verify`, authenticated): the sign-in ceremony machinery run
  statelessly, with a challenge token signed under its own salt so
  step-up, sign-in, and registration tokens are never interchangeable.
  Because `login_user_by_passkey/5` is usernameless, verify asserts
  the credential's owner IS the caller; the challenge also scopes
  `allow_credentials` to the caller's own credential ids so the
  browser never offers a passkey that can only fail. All failures are
  one neutral 422 (the enrollment ceremony's no-oracle convention).
- **Email round-trip** (`POST /auth/step-up/request-link`
  authenticated → emailed link → `POST /auth/step-up/confirm`
  public): a single-use `users_tokens` row, context `"step-up"`,
  hashed at rest, on the magic link's 15-minute lifetime and sharing
  its per-email/per-IP budget. It records WHICH device asked in a new
  `target_token_id` column — a self-referential FK with
  `on_delete: :delete_all`, so revoking a device kills its in-flight
  step-up links — rather than overloading `sent_to` (which keeps its
  email-binding semantics: an address change invalidates pending
  step-up links exactly as it invalidates device tokens). Confirming
  deletes that one token row and sets `stepped_up_at` on the one
  targeted device row — deliberately NOT `consume_login_token/1`,
  which confirms accounts and deletes ALL tokens (documented on #294
  as the wrong tool).

**The confirm endpoint is public.** The emailed link may open in a
different browser than the requesting app (mobile mail clients,
cross-device mailboxes), so demanding the requester's Bearer would
strand exactly the flow the email method exists for. The 32-byte
single-use token is the whole credential — the same stance as every
other emailed confirm (ADR 0013/0026) — and it can only ever elevate
the one row it was minted for. The PWA landing (`/step-up/{token}`)
is button-gated, not confirm-on-mount, so a link-following mail
scanner (or a forwarded link opened reflexively) can't complete a
step-up an attacker requested on a stolen token.

**The gate** (`KammerWeb.ApiStepUp`, answering 401 with the distinct
code `step_up_required` so clients don't read it as "signed out"):

- Passkey enrollment and removal (`/me/passkeys` challenge/create/
  delete) — a passkey outlives device-token revocation.
- Revoking a device other than the caller's own — self-revoke is
  sign-out, which mere possession already allows, and stays ungated.
- Email-change *initiation* (`POST /me/email-change`) — this reverses
  the #258-era rationale ("device tokens have no re-auth equivalent"),
  which this ADR's machinery made false. The confirm side stays
  ungated: its single-use token is already account-bound, and gating
  it would strand a legitimate change when the window expires
  mid-email.

Account deletion stays behind its typed-back-email check only: it
destroys the account rather than repointing credentials at an
attacker, and the deliberate-friction control documented on #258
already covers its honest failure mode.

**Client**: the shared `ApiError` gains the envelope `code` and a
`step_up` kind; one modal (`StepUpModal`) runs either method and the
caller retries its original action transparently — the server-side
window means the retry simply succeeds.

## Consequences

- A transiently stolen device token can no longer mint persistence:
  passkey changes, foreign-device revocation, and email changes all
  demand a fresh root-of-trust assertion the thief doesn't have.
- Two tokens-with-a-window now coexist on `users_tokens`
  (`authenticated_at` for browser sudo-history, `stepped_up_at` for
  API step-up); they never read each other.
- The sign-in flow needed no change: signing in *is* a root-of-trust
  assertion, so freshly exchanged tokens simply start un-stepped-up
  and the first credential change after sign-in asks once.
- ADR 0018's "sudo-mode gated" note is resolved: the PWA surface is
  now gated at least as strongly as the LiveView one it replaced.

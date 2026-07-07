# ADR 0021: Nonce-based CSP instead of `script-src 'unsafe-inline'`

## Context

SPEC §11 tracked a pre-1.0 hardening item: the router's
Content-Security-Policy allowed `script-src 'self' 'unsafe-inline'`,
because the root layout ships exactly one inline `<script>` — the
light/dark theme bootstrap, which has to run before first paint to avoid a
flash of the wrong theme, so it can't be an external, deferred file.
`'unsafe-inline'` on `script-src` defeats the whole point of a script-source
CSP: it permits _any_ inline script, including ones injected by a
successful XSS.

## Decision

`KammerWeb.Plugs.CspNonce` generates a fresh random nonce per request
(`:crypto.strong_rand_bytes/1`, base64), assigns it as `@csp_nonce`, and
sets `script-src 'self' 'nonce-<value>'` — dropping `'unsafe-inline'`
entirely. The root layout's one inline script carries
`nonce={assigns[:csp_nonce]}`. It runs after `put_secure_browser_headers`
in the `:browser` pipeline and overwrites that plug's own CSP default with
the nonce-bearing one.

Colocated LiveView hooks (`Phoenix.LiveView.ColocatedHook`) need no
nonce — CLAUDE.md already establishes they compile into the external
`app.js` bundle, not inline `<script>` tags, so they were never inside
`'unsafe-inline'`'s blast radius to begin with. `style-src 'unsafe-inline'`
is untouched: it's required for the runtime accent-color tinting (inline
`style` attributes), which nonces can't cover (CSP nonces only gate
`<script>`/`<style>` _elements_, not the `style` attribute), and is a much
lower-severity allowance than `script-src` — attacker-controlled CSS can't
execute code the way attacker-controlled script can.

## Consequences

- Any future inline `<script>` block must carry
  `nonce={assigns[:csp_nonce]}` (or `@csp_nonce` inside a LiveView-rendered
  region that receives it as an assign) or the browser silently drops it —
  a real, verified constraint now, not a style preference. Verified with
  `test/kammer_web/plugs/csp_nonce_test.exs` (unit + a real-request
  integration check that the header's nonce matches the rendered script's
  `nonce` attribute) and a live-browser Playwright smoke check (zero CSP
  console violations, the theme script still runs).
- Sobelow's `Config.CSP` check only recognizes a literal
  `content-security-policy` key inside the `put_secure_browser_headers`
  call; it can't see a header set by a separate plug, so it now
  false-positives here — documented and ignored in `.sobelow-conf` with
  the verification steps above, following this repo's established
  documented-ignore pattern for verified-safe findings.
- Inline event-handler attributes (`onclick="..."` etc.) are _not_
  covered by script nonces at all — confirmed none exist anywhere in the
  codebase before making this change, so there was nothing else to
  migrate.

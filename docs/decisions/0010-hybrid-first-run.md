# ADR 0010: Hybrid env + wizard first-run setup

## Context

Declarative deployers (NixOS, Terraform, fleet operators) want everything in
env vars; first-time self-hosters want a guided browser flow. Forcing either
group into the other's model loses them.

## Decision

**Env always wins; the wizard collects the remainder.** Every setup value is
settable via environment. On first boot, a wizard — protected by a setup
token printed to the server logs, permanently locked on completion — collects
whatever env didn't provide: operator email (magic link doubles as the live
SMTP test), first community, first group, invite link, community-creation
policy. Optional demo data with one-click purge.

## Consequences

- Fully env-configured instances boot straight past the wizard.
- The wizard writes to the same settings store env overlays; no second
  configuration system.
- Setup-token-in-logs means only someone with server access can claim a
  fresh instance.

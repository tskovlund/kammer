# ADR 0009: Permission presets, not ACLs — and the visibility invariant

## Context

Per-user file ACLs are the classic path to invisible misconfiguration:
nobody can answer "who can see this folder?" without a debugger.

## Decision

File permissions are **presets only**: baseline inherits owning-scope
membership; per-folder overrides limited to read = `inherit | admins_only`,
write = `inherit(members) | admins_only`; subfolders inherit from parents.

**Invariant, enforced centrally and tested heavily**: file/folder visibility
can never exceed the owning scope's visibility preset.

## Consequences

- The invariant lives in `Kammer.Authorization` with a dedicated
  property-based test suite; any bypass is a release blocker.
- Overrides can only _restrict_, never widen — reasoning stays monotonic.
- "Share this one file with an outsider" is deliberately unsupported in v1.

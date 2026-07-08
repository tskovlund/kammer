# API client

`schema.d.ts` is generated from the Elixir app's OpenAPI document — never
hand-edit it. `client.ts` wraps it with [openapi-fetch](https://openapi-ts.dev/openapi-fetch/)
for a typed, per-instance client (ADR 0001: one client per added instance,
not a module-level singleton).

## Regenerating

The generator needs a running Kammer instance to read `/api/v1/openapi.json`
from — CI's `web-client` job doesn't boot the Elixir app, so this is a
manual step, not part of the build:

```sh
# with a local `mix phx.server` running on :4000
pnpm run generate:api

# or against any other instance
KAMMER_API_URL=https://kammer.example.com/api/v1/openapi.json pnpm run generate:api
```

Commit the regenerated `schema.d.ts` alongside whatever API change prompted
it.

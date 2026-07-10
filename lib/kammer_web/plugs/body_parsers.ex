defmodule KammerWeb.Plugs.BodyParsers do
  @moduledoc """
  Wraps `Plug.Parsers` so the request-body length ceiling tracks
  `UPLOAD_MAX_MB` at runtime instead of being a hardcoded literal
  (issue #234, ADR 0027).

  Installing `Plug.Parsers` directly via the endpoint's `plug` macro
  bakes its `init/1` result in at compile time (`Plug.Builder`'s
  default `:compile` init mode, required in `:prod` for performance —
  `Phoenix.plug_init_mode/0`), which runs *before* `config/runtime.exs`
  sets `:upload_max_megabytes` from the environment. That mismatch is
  exactly the bug this plug fixes: `.env.example` already tells
  operators raising `UPLOAD_MAX_MB` past ~120 needs this ceiling raised
  too, but the ceiling lived as a compile-time literal with no wiring
  back to the env var, so the promise required hand-editing source.

  This plug's own `init/1` is trivial (no options to bake in); the
  real `Plug.Parsers` options — and therefore the length ceiling — are
  computed fresh in `call/2` from `Kammer.Files.upload_limit_bytes/0`,
  so they always reflect the current `UPLOAD_MAX_MB`. `Plug.Parsers`'s
  own `init/1` is cheap (list/tuple construction, no I/O), so doing it
  per-request is not a meaningful cost.

  The parser list, `pass`, and JSON decoder are unchanged from before —
  only the `:length` ceiling is now dynamic. This is the coarse DoS
  bound on the *whole* request body; the precise per-file limit is
  still enforced in `Kammer.Files.create_from_upload/5`. Keeping the
  headroom here matters for the same reason the CVE-2026-56814 Plug
  bump did: this is exactly the multipart-length accounting that bug
  was about, so the ceiling must stay a real, enforced bound — never
  effectively unlimited.
  """

  @behaviour Plug

  @parsers [:urlencoded, :multipart, :json]

  # Headroom above the per-file upload limit for everything in a
  # multipart request that isn't the file itself: MIME boundaries,
  # other form fields, filename/content-type headers. Chosen so the
  # ceiling matches the historical fixed 128_000_000 bytes exactly at
  # the default UPLOAD_MAX_MB=100 (128_000_000 - 100 * 1024 * 1024),
  # preserving existing behaviour for operators who haven't touched
  # UPLOAD_MAX_MB, while now scaling with it for those who have.
  @headroom_bytes 23_142_400

  @impl Plug
  def init(_opts), do: []

  @impl Plug
  def call(conn, _opts) do
    opts =
      Plug.Parsers.init(
        parsers: @parsers,
        pass: ["*/*"],
        length: Kammer.Files.upload_limit_bytes() + @headroom_bytes,
        json_decoder: Phoenix.json_library()
      )

    Plug.Parsers.call(conn, opts)
  end
end

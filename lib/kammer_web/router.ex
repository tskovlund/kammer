defmodule KammerWeb.Router do
  use KammerWeb, :router

  import KammerWeb.ApiAuth, only: [fetch_api_scope: 2, require_api_user: 2]
  import KammerWeb.UserAuth

  # Server-rendered non-SPA surfaces that survive the LiveView removal
  # (#187): syndication feeds, ICS downloads, newsletter unsubscribe.
  # Responses are XML/text/calendar or the one self-contained HTML page
  # (the unsubscribe confirm, #239) — no HTML layout, no LiveView
  # flash, no inline scripts, so the root-layout, live-flash and
  # CSP-nonce plugs the LiveView UI needed are gone. The session is
  # still read (`fetch_current_scope_for_user`) so an authenticated
  # single-event ICS download authorizes like its page.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    # No browser form POSTs through this pipeline anymore (all surviving
    # routes are GET), but keep CSRF protection so any future one is
    # covered by default — and so the session-bearing pipeline isn't a
    # standing Sobelow Config.CSRF finding.
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug KammerWeb.Plugs.RequireSetup
  end

  # Server-rendered MEDIA routes (ICS feeds, single-event ICS, RSS/Atom):
  # `:browser` without `:accepts`. These controllers set their own
  # Content-Type and never format-render, so HTML negotiation buys
  # nothing — and `:accepts, ["html"]` 406s a calendar app or RSS reader
  # that sends a strict Accept header for the endpoint's own media type
  # (`text/calendar`, `application/rss+xml`, `application/atom+xml`),
  # silently failing the subscription (#366). Same reasoning as
  # `:api_binary` (#315) and `:newsletter_one_click` (#239). The session is
  # still read so the single-event ICS download authorizes like its page;
  # `:protect_from_forgery` is kept (a no-op on these GET routes) so the
  # session-bearing pipeline isn't a standing Sobelow Config.CSRF finding.
  pipeline :browser_media do
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug KammerWeb.Plugs.RequireSetup
  end

  # JSON API (ADR 0014): stateless Bearer auth, no sessions, no CSRF
  # surface. The same authorization module answers every question the
  # browser stack asks — the API adds transport, never policy.
  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: KammerWeb.ApiSpec
    plug :fetch_api_scope
  end

  pipeline :api_authenticated do
    plug :require_api_user
  end

  # Binary-serving API routes (single-event ICS, stored-file bytes, the
  # GDPR export zip) set their own Content-Type and never format-render,
  # so JSON content negotiation buys nothing and only 406s a client that
  # sends the natural Accept header for the endpoint's *documented*
  # media type — `text/calendar`, `application/zip`, `image/*` (#315).
  # Same reasoning that dropped `:accepts` from `:newsletter_one_click`
  # (#239). Everything else `:api` does is preserved (the spec module,
  # the auth scope); only the JSON-only negotiation is gone.
  pipeline :api_binary do
    plug OpenApiSpex.Plug.PutApiSpec, module: KammerWeb.ApiSpec
    plug :fetch_api_scope
  end

  # RFC 8058 one-click unsubscribe: a mail client POSTs this with no
  # session and no CSRF token — the signed, expiring token in the URL
  # is the whole credential, same as every other guest link. No
  # session, no CSP, no forgery protection to skip around. No
  # `:accepts` either (#239 review): a headless mail client may send
  # any Accept header or none, and content negotiation would 406 it —
  # the controller sets the response content type itself.
  pipeline :newsletter_one_click do
    plug :put_secure_browser_headers
  end

  # Instance-level secret-token ICS feeds (SPEC §6) — media routes, so
  # `:browser_media` (a calendar app's strict `Accept: text/calendar` must
  # not 406, #366).
  scope "/", KammerWeb do
    pipe_through :browser_media

    get "/calendar/group/:token", CalendarController, :group_feed
    get "/calendar/user/:token", CalendarController, :user_feed
  end

  # The newsletter-unsubscribe confirm page (SPEC §8 — no PWA route for
  # it) is the one genuine HTML surface left, so it keeps `:accepts,
  # ["html"]` on `:browser`. The GET only renders (#239: GET is a safe
  # method, and mail scanners prefetch it); the delete happens on the RFC
  # 8058 POST route below, which its form targets.
  scope "/", KammerWeb do
    pipe_through :browser

    get "/newsletter/unsubscribe/:token", NewsletterController, :unsubscribe
  end

  ## Community-scoped feeds (SPEC §6/§8) — all media (ICS, RSS, Atom), so
  ## `:browser_media` (#366).

  scope "/c/:community_slug", KammerWeb do
    pipe_through :browser_media

    get "/events/:event_id/ics", CalendarController, :event
    # RSS/Atom for public groups (SPEC §8) — no secret token, gated by
    # the same anonymous-visibility check the group page itself uses.
    get "/g/:group_slug/feed.rss", GroupFeedController, :rss
    get "/g/:group_slug/feed.atom", GroupFeedController, :atom
  end

  # Liveness probe for container orchestration — no session, no gating.
  scope "/", KammerWeb do
    get "/healthz", HealthController, :index
  end

  ## JSON API v1 (ADR 0014 + RFC 0001)

  scope "/api/v1", KammerWeb.Api do
    pipe_through :api

    get "/instance", InstanceController, :show
    # Invite preview is public like the /invite/:token landing page —
    # the 24-byte token is the whole credential.
    get "/invites/:token", InviteController, :show
    post "/auth/register", AuthController, :register
    post "/auth/request-link", AuthController, :request_link
    post "/auth/exchange", AuthController, :exchange
    post "/auth/passkey/challenge", AuthController, :passkey_challenge
    post "/auth/passkey/verify", AuthController, :passkey_verify

    # Step-up confirm (issue #294, ADR 0029) is public on purpose: the
    # emailed link may open in a different browser than the requesting
    # app, so no Bearer can be demanded — the single-use token is the
    # whole credential, and it only ever elevates the one device-token
    # row it was minted for. The rest of the step-up surface is in the
    # authenticated scope below.
    post "/auth/step-up/confirm", StepUpController, :confirm

    # First-run setup (issue #185): the operator-bootstrap flow over the
    # API. Gated by the setup token printed to the server logs, not a
    # device token — see SetupController. Public because a pre-setup
    # instance has no operator to authenticate yet. No separate
    # token-check route (issue #230): that would be a boolean oracle
    # over the setup credential, and `complete` already validates the
    # token itself before doing any work.
    get "/setup", SetupController, :status
    post "/setup", SetupController, :complete

    # Public legal pages (issue #185, SPEC §13).
    get "/legal/:key", LegalController, :show

    # Account-less guest surfaces (issue #185, ADR 0013/0024): the signed
    # link in the URL is the whole credential, so these stay tokenless
    # and out of :api_authenticated. Request endpoints email a confirm
    # link; confirm endpoints record and email a management link.
    post "/communities/:community_slug/events/:event_id/guest-rsvp",
         GuestController,
         :request_rsvp

    post "/communities/:community_slug/events/:event_id/slots/:slot_id/guest-claim",
         GuestController,
         :request_claim

    post "/communities/:community_slug/groups/:group_slug/posts/:post_id/guest-comment",
         GuestController,
         :request_comment

    post "/guest/rsvp/confirm", GuestController, :confirm_rsvp
    post "/guest/claim/confirm", GuestController, :confirm_claim
    post "/guest/comment/confirm", GuestController, :confirm_comment

    # The management token is long-lived (unlike the single-use confirm
    # tokens above), so it travels in the `Authorization: Bearer` header
    # instead of the URL (issue #230, ADR 0026) — a path segment would
    # leak it into access logs, proxy logs, browser history, and
    # `Referer`. `GuestController.fetch_manage_token/1` reads it; these
    # routes carry no `:token` param.
    get "/guest/manage", GuestController, :manage
    put "/guest/manage/rsvps/:event_id", GuestController, :set_rsvp
    delete "/guest/manage/claims/:claim_id", GuestController, :release_claim
    put "/guest/manage/subscriptions/:subscription_id", GuestController, :set_cadence
    delete "/guest/manage/subscriptions/:subscription_id", GuestController, :unsubscribe
    delete "/guest/manage", GuestController, :erase

    # Guest newsletter subscriptions (issue #185, SPEC §8). Cadence
    # change and unsubscribe ride the shared guest management token
    # above; the RFC 8058 one-click POST stays a plain-HTTP route.
    post "/communities/:community_slug/groups/:group_slug/newsletter",
         NewsletterController,
         :subscribe

    post "/newsletter/confirm", NewsletterController, :confirm

    # Public content reads (issue #185 slice B): tokenless browsing of
    # public_link/public_listed communities/groups/events/posts, so the
    # PWA can host the guest RSVP/claim/comment request forms (above)
    # on public content pages without an account — the last piece
    # gating the LiveView removal (issue #187). Every read is scoped
    # through `Authorization.publicly_readable?/1`, the same
    # public-and-live boundary the guest request endpoints above and
    # the RSS/Atom feeds already expose (hardened against sealed
    # groups here, see that function's doc) — a guest can browse to
    # exactly the content they could already act on, no more. Nested
    # under `/public` rather than reusing the authenticated resource
    # paths above: `groups/:group_slug/posts` and `events/:event_id`
    # are already taken there, and `public` can never collide with a
    # real `:community_slug` (it's in `Community`'s reserved-slugs
    # list). A community/group/event/post that exists but isn't
    # publicly readable 404s identically to a nonexistent one — no
    # oracle (issue #156/#161).
    scope "/public" do
      # The instance's community directory (issue #260): communities
      # that opted into the anonymous landing page (SPEC §3:
      # `listed_on_instance`, default off) — what the signed-out
      # `InstanceLive.Home` listed, so the PWA landing can too.
      get "/communities", PublicController, :communities
      get "/communities/:community_slug", PublicController, :community
      get "/communities/:community_slug/groups/:group_slug", PublicController, :group

      get "/communities/:community_slug/groups/:group_slug/posts",
          PublicController,
          :group_posts

      get "/communities/:community_slug/groups/:group_slug/posts/:post_id",
          PublicController,
          :post

      get "/communities/:community_slug/events/:event_id", PublicController, :event
    end
  end

  # Post attachments over the tokenless surface (issue #185 slice B):
  # the public twin of the Bearer-authenticated `/api/v1/files/:file_id`
  # routes — same bytes via `FileServing.serve_public/3`, but authorized
  # through `Files.fetch_public_file/1`, which is strictly narrower than
  # what a Bearer-authenticated group member can read: only attachments
  # on a post this same `/public` surface would already show, never a
  # group/community file-space entry on its own. On `:api_binary`, not
  # `:api` — these stream file bytes, so JSON-only Accept negotiation
  # would wrongly 406 an `image/*` request (#315).
  scope "/api/v1/public", KammerWeb.Api do
    pipe_through :api_binary

    get "/files/:file_id", PublicFileController, :show
    get "/files/:file_id/thumbnail", PublicFileController, :thumbnail
    get "/files/:file_id/download", PublicFileController, :download
  end

  # Unaliased scope: RenderSpec is a library plug, not a KammerWeb.Api
  # controller.
  scope "/api/v1" do
    pipe_through :api

    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/api/v1", KammerWeb.Api do
    pipe_through [:api, :api_authenticated]

    delete "/auth/device-token", AuthController, :revoke

    # Step-up re-auth (issue #294, ADR 0029): re-assert a root of trust
    # (passkey assertion, or an emailed link whose public confirm lives
    # in the scope above) before the credential-changing endpoints
    # gated by KammerWeb.ApiStepUp.
    post "/auth/step-up/passkey/challenge", StepUpController, :passkey_challenge
    post "/auth/step-up/passkey/verify", StepUpController, :passkey_verify
    post "/auth/step-up/request-link", StepUpController, :request_link

    get "/home", HomeController, :show

    # Instance operator settings (issue #183), gated to operators in the
    # context. Authenticated; the public `/instance` capability doc stays
    # unauthenticated above.
    get "/instance/settings", InstanceController, :settings
    put "/instance/settings", InstanceController, :update_settings

    # Instance-wide email bans (issue #259, SPEC §11) — the API twin of
    # InstanceLive.Moderation. Operator-only, enforced in the context.
    get "/instance/moderation/bans", ModerationController, :instance_bans
    post "/instance/moderation/bans", ModerationController, :instance_ban
    delete "/instance/moderation/bans/:ban_id", ModerationController, :instance_unban

    # Legal-page editing (issue #259, SPEC §13) — the API twin of
    # LegalLive.Edit; the public read stays unauthenticated above.
    put "/legal/:key", LegalController, :update

    # The caller's own account (issue #182): profile, and devices (#174).
    get "/me", ProfileController, :show
    put "/me", ProfileController, :update
    get "/me/devices", ProfileController, :devices
    delete "/me/devices/:device_id", ProfileController, :revoke_device

    # Passkey enrollment (issue #260 port 5b, ADR 0018): the
    # authenticated twin of the /auth/passkey/* sign-in ceremony. The
    # literal `challenge` segment is declared before the bare collection
    # so it can never be captured by a param route.
    post "/me/passkeys/challenge", PasskeyController, :challenge
    get "/me/passkeys", PasskeyController, :index
    post "/me/passkeys", PasskeyController, :create
    delete "/me/passkeys/:passkey_id", PasskeyController, :delete

    # Account lifecycle (issue #258, SPEC §12): email change, export,
    # deletion. The email-change confirm is authenticated — the emailed
    # token is bound to the requesting account, so the PWA landing page
    # sends it back with the device token it already holds. Email-change
    # initiation, export, and deletion are step-up-gated in the
    # controller (ADR 0029; export/deletion widened on #323).
    post "/me/email-change", AccountController, :request_email_change
    post "/me/email-change/confirm", AccountController, :confirm_email_change
    # `GET /me/export` streams a zip — it lives in the `:api_binary`
    # scope below so `Accept: application/zip` isn't 406'd (#315).
    delete "/me", AccountController, :delete

    # Personal iCal subscription token (issue #260, SPEC §6): the URL for
    # the caller's merged-events feed, generated on first fetch.
    get "/me/calendar-token", CalendarController, :me
    # Revoke a leaked calendar link by minting a fresh token (#291).
    post "/me/calendar-token/reset", CalendarController, :me_reset

    post "/invites/:token/accept", InviteController, :accept

    get "/communities", CommunityController, :index
    post "/communities", CommunityController, :create
    get "/communities/:community_slug/groups", CommunityController, :groups
    post "/communities/:community_slug/groups", GroupController, :create

    # The people rung (issue #182): directory/roster, membership
    # lifecycle, invites, per-community profile, group membership
    # management, and the per-group notification level. The scope
    # writes the shared prefix once and adds no alias of its own.
    scope "/communities/:community_slug" do
      # Management/admin surfaces (issue #183): community settings, the
      # moderation queue + bans, and the audit log. Literal segments
      # (`moderation`, `audit-log`) never collide with the member routes.
      put "/", CommunityController, :update

      get "/moderation/reports", ModerationController, :reports
      post "/moderation/reports/:report_id/resolve", ModerationController, :resolve
      post "/moderation/reports/:report_id/dismiss", ModerationController, :dismiss
      get "/moderation/bans", ModerationController, :bans
      post "/moderation/bans", ModerationController, :ban
      delete "/moderation/bans/:ban_id", ModerationController, :unban
      get "/audit-log", ModerationController, :audit_log

      get "/members", MemberController, :index
      put "/members/:user_id/role", MemberController, :update_role
      delete "/members/:user_id", MemberController, :remove
      delete "/membership", MemberController, :leave

      get "/profile", ProfileController, :community_profile
      put "/profile", ProfileController, :update_community_profile

      get "/invites", InviteController, :index
      post "/invites", InviteController, :create
      delete "/invites/:invite_id", InviteController, :revoke

      # Custom profile-field definitions (issue #259, ADR 0020): the
      # roster's columns, manager-only. `custom-fields` is a literal
      # segment — no collision with the member routes.
      get "/custom-fields", CustomFieldController, :index
      post "/custom-fields", CustomFieldController, :create
      put "/custom-fields/:id", CustomFieldController, :update
      delete "/custom-fields/:id", CustomFieldController, :delete

      scope "/groups/:group_slug" do
        # Group management (issue #183): settings, feature toggles
        # (ADR 0016), archive/unarchive. `features`/`archive` are literal
        # segments — no collision with the member routes below.
        put "/", GroupController, :update
        delete "/", GroupController, :delete
        put "/features", GroupController, :features
        put "/archive", GroupController, :archive
        delete "/archive", GroupController, :unarchive

        get "/invites", InviteController, :index
        post "/invites", InviteController, :create

        get "/members", GroupMemberController, :index
        put "/members/:user_id/role", GroupMemberController, :update_role
        delete "/members/:user_id", GroupMemberController, :remove
        put "/membership", GroupMemberController, :join
        delete "/membership", GroupMemberController, :leave

        get "/join-requests", GroupMemberController, :index_join_requests
        put "/join-requests/:request_id/approval", GroupMemberController, :approve_join_request
        delete "/join-requests/:request_id", GroupMemberController, :deny_join_request

        get "/notification-level", GroupMemberController, :show_notification_level
        put "/notification-level", GroupMemberController, :update_notification_level
      end
    end

    get "/communities/:community_slug/groups/:group_slug/posts", PostController, :index
    post "/communities/:community_slug/groups/:group_slug/posts", PostController, :create

    # Feed write parity (issue #178). Scoped so the long shared prefix
    # is written once; the scope adds no alias of its own.
    scope "/communities/:community_slug/groups/:group_slug" do
      post "/uploads", UploadController, :create

      # Group file library (issue #181): folders, file entries + versions
      # (ADR 0017), upload/download, and manager folder/override tools —
      # the folder-permission invariant (ADR 0009) is enforced in the
      # context. Literal `/files` and `/folders` segments never collide
      # with `/posts`, so ordering is unconstrained here.
      get "/files", FileLibraryController, :index
      post "/files", FileLibraryController, :upload
      get "/files/:file_id", FileLibraryController, :show
      delete "/files/:file_id", FileLibraryController, :delete
      post "/files/:file_id/versions", FileLibraryController, :upload_version
      delete "/files/:file_id/versions/:version_id", FileLibraryController, :delete_version

      post "/folders", FileLibraryController, :create_folder
      put "/folders/:folder_id/overrides", FileLibraryController, :update_folder
      delete "/folders/:folder_id", FileLibraryController, :delete_folder

      scope "/posts/:post_id" do
        put "/", PostController, :update
        delete "/", PostController, :delete
        put "/pin", PostController, :pin
        delete "/pin", PostController, :unpin
        post "/reactions", PostController, :react
        put "/poll/votes", PostController, :vote
        put "/acknowledgment", PostController, :acknowledge
        get "/acknowledgments", PostController, :acknowledgments
        post "/report", PostController, :report

        post "/comments", PostController, :create_comment
        put "/comments/:comment_id", PostController, :update_comment
        delete "/comments/:comment_id", PostController, :delete_comment
        post "/comments/:comment_id/reactions", PostController, :react_comment
        post "/comments/:comment_id/report", PostController, :report_comment
      end
    end

    # Post attachments (and any stored file the caller may see) over
    # Bearer auth serve file bytes — in the `:api_binary` scope below,
    # so an `image/*` Accept isn't 406'd (#315).

    get "/communities/:community_slug/events", EventController, :index
    # A recurring series' organizer view (issue #260, SPEC §6): the
    # occurrence list + attendance matrix, organizer-only. Declared
    # before the :event_id show route — "series" is a literal segment,
    # and the extra path segment keeps the two unambiguous regardless.
    get "/communities/:community_slug/events/series/:series_id", EventController, :series
    get "/communities/:community_slug/events/:event_id", EventController, :show

    # Events write parity (issue #180). Creation is group-scoped (an
    # event belongs to a group); everything else addresses the event by
    # id within its community. The scope writes the shared prefix once.
    post "/communities/:community_slug/groups/:group_slug/events", EventController, :create

    # A group's iCal subscription token (issue #260, SPEC §6): gated as
    # the group's own feed is (viewable + events feature on).
    get "/communities/:community_slug/groups/:group_slug/calendar-token",
        CalendarController,
        :group

    # `GET .../events/:event_id/ics` (Bearer, issue #307) serves
    # `text/calendar` — in the `:api_binary` scope below so that
    # documented Accept isn't 406'd (#315).

    scope "/communities/:community_slug/events/:event_id" do
      put "/rsvp", EventController, :rsvp
      put "/", EventController, :update
      delete "/", EventController, :delete
      # Per-occurrence override (ADR 0019): cancel keeps the row and its
      # RSVP/comment history, just excludes it from listings and feeds.
      put "/cancellation", EventController, :cancel
      delete "/cancellation", EventController, :uncancel

      post "/slots", EventController, :create_slot
      delete "/slots/:slot_id", EventController, :delete_slot
      put "/slots/:slot_id/claim", EventController, :claim_slot
      delete "/slots/:slot_id/claim", EventController, :unclaim_slot

      post "/comments", EventController, :create_comment
      put "/comments/:comment_id", EventController, :update_comment
      delete "/comments/:comment_id", EventController, :delete_comment
      post "/comments/:comment_id/reactions", EventController, :react_comment
      post "/comments/:comment_id/report", EventController, :report_comment
    end

    # Collaborative tools and global search (issue #184), each per-group
    # and feature-gated (ADR 0016). Creation is group-scoped (the tool
    # belongs to a group); a poll/assignment/decision is then addressed
    # by id within its community, exactly as events are. Literal
    # `availability`/`assignments`/`decisions`/`search` segments never
    # collide with the member or event routes.
    get "/communities/:community_slug/search", SearchController, :search

    get "/communities/:community_slug/availability", AvailabilityController, :index

    post "/communities/:community_slug/groups/:group_slug/availability",
         AvailabilityController,
         :create

    scope "/communities/:community_slug/availability/:poll_id" do
      get "/", AvailabilityController, :show
      put "/responses", AvailabilityController, :respond
      put "/closure", AvailabilityController, :close
      put "/conversion", AvailabilityController, :convert
    end

    get "/communities/:community_slug/groups/:group_slug/assignments",
        AssignmentController,
        :index

    post "/communities/:community_slug/groups/:group_slug/assignments",
         AssignmentController,
         :create

    scope "/communities/:community_slug/assignments/:assignment_id" do
      get "/", AssignmentController, :show
      put "/", AssignmentController, :update
      delete "/", AssignmentController, :delete
      put "/claim", AssignmentController, :claim
      delete "/claim", AssignmentController, :unclaim
      put "/completion", AssignmentController, :complete
      delete "/completion", AssignmentController, :reopen
      post "/comments", AssignmentController, :create_comment
      post "/comments/:comment_id/report", AssignmentController, :report_comment
    end

    get "/communities/:community_slug/groups/:group_slug/decisions", DecisionController, :index
    post "/communities/:community_slug/groups/:group_slug/decisions", DecisionController, :create

    scope "/communities/:community_slug/decisions/:decision_id" do
      get "/", DecisionController, :show
      put "/outcome", DecisionController, :record_outcome
    end

    get "/notifications", NotificationController, :index
    # Literal before wildcard, same reason as the browser routes above.
    put "/notifications/read-all", NotificationController, :mark_all_read
    put "/notifications/:notification_id/read", NotificationController, :mark_read

    post "/push-subscriptions", PushSubscriptionController, :create
    delete "/push-subscriptions", PushSubscriptionController, :delete
  end

  # Bearer-authenticated binary downloads (#315): stored-file bytes, the
  # single-event ICS, and the GDPR export zip. Same auth as the JSON
  # scope above (`:api_binary` keeps the spec module and `fetch_api_scope`,
  # then `:api_authenticated` requires a user), but without JSON-only
  # Accept negotiation, so a client sending the endpoint's documented
  # media type isn't 406'd. Every path here is unique (the public file
  # twins live under `/api/v1/public`, the ICS suffix distinguishes it
  # from the event routes), so pulling them into their own scope changes
  # no route matching.
  scope "/api/v1", KammerWeb.Api do
    pipe_through [:api_binary, :api_authenticated]

    get "/files/:file_id", FileController, :show
    get "/files/:file_id/thumbnail", FileController, :thumbnail
    get "/files/:file_id/download", FileController, :download

    get "/me/export", AccountController, :export

    get "/communities/:community_slug/events/:event_id/ics", CalendarController, :event
  end

  # RFC 8058 one-click unsubscribe (SPEC §8): a mail client POSTs this
  # with no session and no CSRF token — the scoped, expiring token in
  # the URL is the whole credential (issue #233). The human-facing GET
  # confirm page in the :browser scope above submits its form here too
  # (#239) — the token authorizes the POST the same either way.
  scope "/", KammerWeb do
    pipe_through [:newsletter_one_click]

    post "/newsletter/unsubscribe/:token", NewsletterController, :unsubscribe_one_click
  end

  # Swoosh mailbox preview in development only — the Playwright e2e suite
  # reads sent magic-link emails from /dev/mailbox/json to drive the
  # sign-in flows. A plain Swoosh Plug, not LiveView-coupled (LiveDashboard
  # went with the #187 cut). Defined before the PWA catch-all below so
  # /dev/mailbox matches ahead of the "/" wildcard.
  if Application.compile_env(:kammer, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Instance-served PWA (ADR 0024, issue #176/#187)

  # The SPA is a static artifact: no session, no CSRF surface. It only
  # needs HTML negotiation and the baseline secure headers (PwaController
  # sets the page's own CSP — a static bundle can't take a nonce-based
  # one).
  pipeline :pwa do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers
  end

  # Wildcard fallback so client-side routes (e.g. /sign-in/{token} from a
  # magic-link email) deep-link straight into the SPA: real files were
  # already served by Plug.Static in the endpoint, so whatever reaches
  # this route gets index.html and lets the client router take over.
  # Scoped under :pwa_base_path, which is now "/" (the #187 flip) — so
  # this scope is defined LAST on purpose: Phoenix matches scopes in
  # definition order, and at "/" an earlier catch-all would swallow
  # /api, /healthz, the ICS/RSS feeds and the newsletter routes above.
  scope Application.compile_env!(:kammer, :pwa_base_path), KammerWeb do
    pipe_through :pwa

    get "/*path", PwaController, :index
  end
end

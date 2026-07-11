defmodule KammerWeb.Router do
  use KammerWeb, :router

  import KammerWeb.ApiAuth, only: [fetch_api_scope: 2, require_api_user: 2]
  import KammerWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KammerWeb.Layouts, :root}
    plug :protect_from_forgery

    # SPEC §11: CSP. 'unsafe-inline' styles are required by the runtime
    # accent-tinting (style attributes); scripts are nonce-gated instead
    # of 'unsafe-inline' (pre-1.0 hardening) — see CspNonce.
    plug :put_secure_browser_headers
    plug KammerWeb.Plugs.CspNonce

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

  # RFC 8058 one-click unsubscribe: a mail client POSTs this with no
  # session and no CSRF token — the signed, expiring token in the URL
  # is the whole credential, same as every other guest link. No
  # session, no CSP, no forgery protection to skip around.
  pipeline :newsletter_one_click do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers
  end

  scope "/", KammerWeb do
    pipe_through :browser

    live_session :instance,
      on_mount: [{KammerWeb.UserAuth, :mount_current_scope}] do
      live "/", InstanceLive.Home, :index
      live "/invite/:token", InviteLive.Show, :show
      live "/setup", SetupLive.Wizard, :index
      live "/legal/:key", LegalLive.Show, :show
    end

    get "/invite/:token/accept", InviteController, :accept

    get "/files/:id", FileController, :show
    get "/files/:id/thumbnail", FileController, :thumbnail
    get "/files/:id/download", FileController, :download

    get "/calendar/group/:token", CalendarController, :group_feed
    get "/calendar/user/:token", CalendarController, :user_feed
  end

  ## Community-scoped routes

  scope "/c/:community_slug", KammerWeb do
    pipe_through :browser

    get "/events/:event_id/ics", CalendarController, :event
    # RSS/Atom for public groups (SPEC §8) — no secret token, gated by
    # the same anonymous-visibility check the group page itself uses.
    get "/g/:group_slug/feed.rss", GroupFeedController, :rss
    get "/g/:group_slug/feed.atom", GroupFeedController, :atom

    # Member-only pages. Defined BEFORE the public session so literal
    # segments win over the public wildcard (/events/new must not be
    # captured by /events/:event_id).
    live_session :community_member,
      on_mount: [
        {KammerWeb.UserAuth, :require_authenticated},
        {KammerWeb.CommunityScope, :require_member}
      ] do
      live "/groups", GroupLive.Index, :index
      live "/groups/new", GroupLive.New, :new
      live "/g/:group_slug/settings", GroupLive.Settings, :edit
      live "/g/:group_slug/files", FileLive.Index, :group
      live "/g/:group_slug/availability/new", AvailabilityLive.New, :new
      live "/g/:group_slug/assignments", AssignmentLive.Index, :index
      live "/g/:group_slug/assignments/:assignment_id", AssignmentLive.Show, :show
      live "/g/:group_slug/decisions", DecisionLive.Index, :index
      live "/files", FileLive.Index, :community
      live "/members", CommunityLive.Members, :index
      live "/complete-profile", CommunityLive.CompleteProfile, :edit
      live "/moderation", ModerationLive.Index, :index
      live "/settings", CommunityLive.Settings, :edit
      live "/events", EventLive.Index, :index
      live "/events/new", EventLive.New, :new
      live "/events/series/:series_id", EventLive.Series, :show
      live "/notifications", NotificationLive.Index, :index
    end

    # Public-capable pages: the pages themselves authorize via
    # Kammer.Authorization (public groups and community public pages are
    # readable without an account).
    live_session :community_public,
      on_mount: [
        {KammerWeb.UserAuth, :mount_current_scope},
        {KammerWeb.CommunityScope, :assign_community}
      ] do
      live "/", CommunityLive.Home, :show
      live "/search", SearchLive.Index, :index
      live "/g/:group_slug", GroupLive.Show, :show
      # Event pages gate through the authorization module like group
      # feeds do: anonymous viewers see events of public groups only —
      # which is what guest RSVP (SPEC §6) requires.
      live "/events/:event_id", EventLive.Show, :show
      live "/availability/:poll_id", AvailabilityLive.Show, :show
    end
  end

  scope "/", KammerWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :authenticated_instance,
      on_mount: [{KammerWeb.UserAuth, :require_authenticated}] do
      live "/communities/new", CommunityLive.New, :new
      live "/users/settings/servers", UserLive.Bookmarks, :index
      live "/legal/:key/edit", LegalLive.Edit, :edit
      live "/instance/settings", InstanceLive.Settings, :edit
      live "/instance/moderation", InstanceLive.Moderation, :index
    end
  end

  # Liveness probe for container orchestration — no session, no gating.
  scope "/", KammerWeb do
    get "/healthz", HealthController, :index
  end

  ## Instance-served PWA (ADR 0024, issue #176)

  # The SPA is a static artifact: no session, no CSRF surface, no
  # LiveView. It only needs HTML negotiation and the baseline secure
  # headers (PwaController sets the page's own CSP — a static bundle
  # can't take the nonce-based one the browser pipeline builds).
  pipeline :pwa do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers
  end

  # Wildcard fallback so client-side routes (e.g. /app/sign-in/{token})
  # deep-link straight into the SPA: real files were already served by
  # Plug.Static in the endpoint, so whatever reaches this route gets
  # index.html and lets the client router take over. Scoped strictly
  # under :pwa_base_path — at "/app" it can never shadow /api, /live,
  # /healthz (at the #187 flip to "/" this scope must move to the END
  # of the router: scopes match in definition order),
  # the RSS/iCal feeds, or the LiveView routes at "/". Flip note (#187):
  # see config/config.exs.
  scope Application.compile_env!(:kammer, :pwa_base_path), KammerWeb do
    pipe_through :pwa

    get "/*path", PwaController, :index
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

      # Post attachments over the tokenless surface (issue #185 slice
      # B): the public twin of the Bearer-authenticated
      # `/api/v1/files/:file_id` routes below — same bytes via
      # `FileServing.serve_public/3`, but authorized through
      # `Files.fetch_public_file/1`, which is strictly narrower than
      # what a Bearer-authenticated group member can read: only
      # attachments on a post this same `/public` surface would already
      # show, never a group/community file-space entry on its own. The
      # literal `files` segment can't collide with `:community_slug`
      # (it's not nested under `/communities`).
      get "/files/:file_id", PublicFileController, :show
      get "/files/:file_id/thumbnail", PublicFileController, :thumbnail
      get "/files/:file_id/download", PublicFileController, :download
    end
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

    # Account lifecycle (issue #258, SPEC §12): email change, export,
    # deletion. The email-change confirm is authenticated — the emailed
    # token is bound to the requesting account, so the PWA landing page
    # sends it back with the device token it already holds.
    post "/me/email-change", AccountController, :request_email_change
    post "/me/email-change/confirm", AccountController, :confirm_email_change
    get "/me/export", AccountController, :export
    delete "/me", AccountController, :delete

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
    # Bearer auth — the API twin of the browser /files routes.
    get "/files/:file_id", FileController, :show
    get "/files/:file_id/thumbnail", FileController, :thumbnail
    get "/files/:file_id/download", FileController, :download

    get "/communities/:community_slug/events", EventController, :index
    get "/communities/:community_slug/events/:event_id", EventController, :show

    # Events write parity (issue #180). Creation is group-scoped (an
    # event belongs to a group); everything else addresses the event by
    # id within its community. The scope writes the shared prefix once.
    post "/communities/:community_slug/groups/:group_slug/events", EventController, :create

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

  # Guest links (SPEC §6/§11): signed, expiring tokens are the whole
  # credential — no account, no session requirements beyond the browser
  # pipeline. Confirm records the RSVP or comment; manage lists, changes,
  # and erases everything the guest created.
  scope "/", KammerWeb do
    pipe_through [:browser]

    get "/guest/rsvp/confirm/:token", GuestRsvpController, :confirm
    get "/guest/comment/confirm/:token", GuestCommentController, :confirm
    get "/guest/claim/confirm/:token", GuestClaimController, :confirm
    get "/newsletter/confirm/:token", NewsletterController, :confirm
    # `:token` alone (issue #233) — it's a scoped, single-purpose
    # unsubscribe token that names its own subscription, not the
    # guest's full-power management token, so there's no separate
    # `:subscription_id` segment to trust.
    get "/newsletter/unsubscribe/:token", NewsletterController, :unsubscribe

    live_session :guest_links,
      on_mount: [{KammerWeb.UserAuth, :mount_current_scope}] do
      live "/guest/manage/:token", GuestLive.Manage, :manage
    end
  end

  scope "/", KammerWeb do
    pipe_through [:newsletter_one_click]

    post "/newsletter/unsubscribe/:token", NewsletterController, :unsubscribe_one_click
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:kammer, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: KammerWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", KammerWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/users/settings/export", GdprController, :export

    live_session :require_authenticated_user,
      on_mount: [{KammerWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/users/settings/devices", UserLive.Devices, :index
    end
  end

  scope "/", KammerWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{KammerWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    post "/users/log-in/passkey", UserSessionController, :create_from_passkey
    delete "/users/log-out", UserSessionController, :delete
  end
end

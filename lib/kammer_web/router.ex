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
    post "/auth/register", AuthController, :register
    post "/auth/request-link", AuthController, :request_link
    post "/auth/exchange", AuthController, :exchange
    post "/auth/passkey/challenge", AuthController, :passkey_challenge
    post "/auth/passkey/verify", AuthController, :passkey_verify
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
    get "/communities", CommunityController, :index
    get "/communities/:community_slug/groups", CommunityController, :groups
    get "/communities/:community_slug/groups/:group_slug/posts", PostController, :index
    post "/communities/:community_slug/groups/:group_slug/posts", PostController, :create

    # Feed write parity (issue #178). Scoped so the long shared prefix
    # is written once; the scope adds no alias of its own.
    scope "/communities/:community_slug/groups/:group_slug" do
      post "/uploads", UploadController, :create

      scope "/posts/:post_id" do
        put "/", PostController, :update
        delete "/", PostController, :delete
        put "/pin", PostController, :pin
        delete "/pin", PostController, :unpin
        post "/reactions", PostController, :react
        put "/poll/votes", PostController, :vote
        put "/acknowledgment", PostController, :acknowledge
        get "/acknowledgments", PostController, :acknowledgments

        post "/comments", PostController, :create_comment
        put "/comments/:comment_id", PostController, :update_comment
        delete "/comments/:comment_id", PostController, :delete_comment
        post "/comments/:comment_id/reactions", PostController, :react_comment
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
    get "/newsletter/unsubscribe/:token/:subscription_id", NewsletterController, :unsubscribe

    live_session :guest_links,
      on_mount: [{KammerWeb.UserAuth, :mount_current_scope}] do
      live "/guest/manage/:token", GuestLive.Manage, :manage
    end
  end

  scope "/", KammerWeb do
    pipe_through [:newsletter_one_click]

    post "/newsletter/unsubscribe/:token/:subscription_id",
         NewsletterController,
         :unsubscribe_one_click
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

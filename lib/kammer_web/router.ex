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
    # accent-tinting (style attributes) and inline theme bootstrap.
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; " <>
          "script-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss:; " <>
          "object-src 'none'; frame-ancestors 'self'; base-uri 'self'"
    }

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
      live "/files", FileLive.Index, :community
      live "/members", CommunityLive.Members, :index
      live "/settings", CommunityLive.Settings, :edit
      live "/events", EventLive.Index, :index
      live "/events/new", EventLive.New, :new
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
      live "/g/:group_slug", GroupLive.Show, :show
      # Event pages gate through the authorization module like group
      # feeds do: anonymous viewers see events of public groups only —
      # which is what guest RSVP (SPEC §6) requires.
      live "/events/:event_id", EventLive.Show, :show
    end
  end

  scope "/", KammerWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :authenticated_instance,
      on_mount: [{KammerWeb.UserAuth, :require_authenticated}] do
      live "/communities/new", CommunityLive.New, :new
      live "/users/settings/servers", UserLive.Bookmarks, :index
      live "/legal/:key/edit", LegalLive.Edit, :edit
    end
  end

  # Liveness probe for container orchestration — no session, no gating.
  scope "/", KammerWeb do
    get "/healthz", HealthController, :index
  end

  ## JSON API v1 (ADR 0014 + RFC 0001)

  scope "/api/v1", KammerWeb.Api do
    pipe_through :api

    get "/instance", InstanceController, :show
    post "/auth/request-link", AuthController, :request_link
    post "/auth/exchange", AuthController, :exchange
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

    post "/communities/:community_slug/groups/:group_slug/posts/:post_id/comments",
         PostController,
         :create_comment

    get "/communities/:community_slug/events", EventController, :index
    get "/communities/:community_slug/events/:event_id", EventController, :show
    put "/communities/:community_slug/events/:event_id/rsvp", EventController, :rsvp
  end

  # Guest links (SPEC §6/§11): signed, expiring tokens are the whole
  # credential — no account, no session requirements beyond the browser
  # pipeline. Confirm records the RSVP; manage changes or erases it.
  scope "/", KammerWeb do
    pipe_through [:browser]

    get "/guest/rsvp/confirm/:token", GuestRsvpController, :confirm

    live_session :guest_links,
      on_mount: [{KammerWeb.UserAuth, :mount_current_scope}] do
      live "/guest/rsvp/:token", GuestRsvpLive.Manage, :manage
    end
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
    delete "/users/log-out", UserSessionController, :delete
  end
end

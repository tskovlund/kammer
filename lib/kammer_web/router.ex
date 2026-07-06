defmodule KammerWeb.Router do
  use KammerWeb, :router

  import KammerWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KammerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  scope "/", KammerWeb do
    pipe_through :browser

    live_session :instance,
      on_mount: [{KammerWeb.UserAuth, :mount_current_scope}] do
      live "/", InstanceLive.Home, :index
      live "/invite/:token", InviteLive.Show, :show
    end

    get "/invite/:token/accept", InviteController, :accept
  end

  ## Community-scoped routes

  scope "/c/:community_slug", KammerWeb do
    pipe_through :browser

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
    end

    # Member-only pages.
    live_session :community_member,
      on_mount: [
        {KammerWeb.UserAuth, :require_authenticated},
        {KammerWeb.CommunityScope, :require_member}
      ] do
      live "/groups", GroupLive.Index, :index
      live "/groups/new", GroupLive.New, :new
      live "/g/:group_slug/settings", GroupLive.Settings, :edit
      live "/members", CommunityLive.Members, :index
      live "/settings", CommunityLive.Settings, :edit
      live "/events", EventLive.Index, :index
      live "/notifications", NotificationLive.Index, :index
    end
  end

  scope "/", KammerWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :authenticated_instance,
      on_mount: [{KammerWeb.UserAuth, :require_authenticated}] do
      live "/communities/new", CommunityLive.New, :new
      live "/users/settings/servers", UserLive.Bookmarks, :index
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

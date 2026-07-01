defmodule VigilWeb.Router do
  use VigilWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {VigilWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug VigilWeb.SessionPlug
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug VigilWeb.TokenAuthPlug
  end

  pipeline :api_require_auth do
    plug VigilWeb.Plugs.RequireAuthPlug
  end

  scope "/", VigilWeb do
    pipe_through :browser

    live_session :public,
      on_mount: [{VigilWeb.LiveAuth, :mount_current_user}] do
      live "/users/log_in", Live.UserSessionLive
    end

    post "/users/log_in", UserSessionController, :create
    delete "/users/log_out", UserSessionController, :delete

    live_session :authenticated,
      on_mount: [{VigilWeb.LiveAuth, :require_authenticated}] do
      live "/", DashboardLive
      live "/settings/tokens", Live.Settings.APITokensLive
    end

    live_session :inventory_access,
      on_mount: [{VigilWeb.LiveAuth, {:require_permission, "inventory:node:read"}}] do
      live "/inventory", InventoryLive
      live "/inventory/node/:id", NodeDetailLive
      live "/inventory/node/:id/:tab", NodeDetailLive
    end

    live_session :journal_access,
      on_mount: [{VigilWeb.LiveAuth, {:require_permission, "journal:read"}}] do
      live "/journal", GlobalTimelineLive
    end

    live_session :health_access,
      on_mount: [{VigilWeb.LiveAuth, {:require_permission, "integration:health:read"}}] do
      live "/health", Live.HealthLive
    end

    live_session :execution_submit,
      on_mount: [{VigilWeb.LiveAuth, {:require_permission, "execution:submit"}}] do
      live "/executions/new", Live.ExecutionSubmitLive
    end

    live_session :execution_read,
      on_mount: [{VigilWeb.LiveAuth, {:require_permission, "execution:read"}}] do
      live "/executions", Live.ExecutionLive
      live "/executions/:group_id", Live.ExecutionLive
    end

    live_session :admin,
      on_mount: [{VigilWeb.LiveAuth, {:require_permission, "platform:admin"}}] do
      live "/settings/integrations", Live.Settings.IntegrationsLive
      live "/settings/roles", Live.Settings.RolesLive
    end
  end

  scope "/api/v1", VigilWeb.API do
    pipe_through [:api, :api_require_auth]

    post "/executions", ExecutionController, :create
  end

  scope "/", VigilWeb do
    get "/_health", HealthController, :show
  end
end

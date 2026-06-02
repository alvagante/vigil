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
      live "/health", Live.HealthLive
      live "/inventory", InventoryLive
      live "/inventory/node/:id", NodeDetailLive
      live "/inventory/node/:id/:tab", NodeDetailLive
      live "/executions", Live.ExecutionLive
      live "/executions/new", Live.ExecutionSubmitLive
      live "/executions/:group_id", Live.ExecutionLive
    end

    live_session :admin,
      on_mount: [{VigilWeb.LiveAuth, {:require_permission, "platform:admin"}}] do
      live "/settings/integrations", Live.Settings.IntegrationsLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", VigilWeb do
  #   pipe_through :api
  # end
end

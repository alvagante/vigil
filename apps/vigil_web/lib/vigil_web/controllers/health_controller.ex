defmodule VigilWeb.HealthController do
  use VigilWeb, :controller

  @version Mix.Project.config()[:version]

  def show(conn, _params) do
    json(conn, %{status: "ok", version: @version})
  end
end

defmodule VigilWeb.Plugs.RequireAuthPlug do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_status(:unauthorized)
      |> Phoenix.Controller.json(%{error: "unauthorized"})
      |> halt()
    end
  end
end

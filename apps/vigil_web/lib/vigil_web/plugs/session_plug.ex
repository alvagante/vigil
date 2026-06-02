defmodule VigilWeb.SessionPlug do
  import Plug.Conn

  alias Vigil.Core.Accounts

  @session_key "_vigil_token"

  def init(opts), do: opts

  def call(conn, _opts) do
    token = get_session(conn, @session_key)
    assign_user(conn, token)
  end

  defp assign_user(conn, nil), do: conn

  defp assign_user(conn, token) do
    case Accounts.fetch_session(token) do
      {:ok, _session, user} -> assign(conn, :current_user, user)
      {:error, _} -> conn
    end
  end
end

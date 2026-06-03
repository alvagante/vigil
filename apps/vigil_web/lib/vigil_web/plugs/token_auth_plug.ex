defmodule VigilWeb.TokenAuthPlug do
  import Plug.Conn

  alias Vigil.Core.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      case extract_token(conn) do
        nil ->
          conn

        token ->
          case Accounts.lookup_token(token) do
            {:ok, _record, user} ->
              conn
              |> assign(:current_user, user)
              |> assign(:auth_source, :token)

            :error ->
              conn
          end
      end
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end
end

defmodule VigilWeb.RBACPlug do
  import Plug.Conn

  alias Vigil.Core.RBAC
  alias Vigil.Core.RBAC.Context

  def init(opts), do: opts

  def call(conn, permission: action) do
    case conn.assigns[:current_user] do
      nil ->
        conn |> put_status(:unauthorized) |> halt()

      user ->
        case RBAC.check(user, action, %Context{}) do
          :ok -> conn
          {:error, :denied} -> conn |> put_status(:forbidden) |> halt()
        end
    end
  end
end

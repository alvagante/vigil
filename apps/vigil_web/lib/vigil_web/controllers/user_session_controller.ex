defmodule VigilWeb.UserSessionController do
  use VigilWeb, :controller

  alias Vigil.Core.{Accounts, Audit}

  def create(conn, %{"username" => username, "password" => password}) do
    case Accounts.authenticate_user(username, password) do
      {:ok, user} ->
        {:ok, token, _session} = Accounts.create_session(user)
        action = if user.is_break_glass, do: "auth.login.break_glass", else: "auth.login"
        params = if user.is_break_glass, do: %{break_glass: true}, else: %{}
        Audit.write_finalized(user, action, :success, params: params)

        conn
        |> configure_session(renew: true)
        |> put_session("_vigil_token", token)
        |> redirect(to: ~p"/")

      {:error, :invalid_credentials} ->
        Audit.write_finalized(%{id: username}, "auth.login", :failure)

        conn
        |> put_flash(:error, "Invalid username or password.")
        |> redirect(to: ~p"/users/log_in")
    end
  end

  def delete(conn, _params) do
    token = get_session(conn, "_vigil_token")
    if token, do: Accounts.delete_session(token)

    if user = conn.assigns[:current_user] do
      Audit.write_finalized(user, "auth.logout", :success)
    end

    conn
    |> delete_session("_vigil_token")
    |> redirect(to: ~p"/users/log_in")
  end
end

defmodule VigilWeb.LiveAuth do
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias Vigil.Core.{Accounts, RBAC, RBAC.Context}

  @session_key "_vigil_token"

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(session, socket)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_user(session, socket)

    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/users/log_in")}
    end
  end

  def on_mount({:require_permission, action}, _params, session, socket) do
    socket = mount_current_user(session, socket)

    case socket.assigns[:current_user] do
      nil ->
        {:halt, redirect(socket, to: "/users/log_in")}

      user ->
        case RBAC.check(user, action, %Context{}) do
          :ok ->
            {:cont, socket}

          {:error, :denied} ->
            {:halt, redirect(socket, to: "/")}
        end
    end
  end

  defp mount_current_user(session, socket) do
    token = session[@session_key]

    user =
      if is_binary(token) do
        case Accounts.fetch_session(token) do
          {:ok, _session_record, user} -> user
          _ -> nil
        end
      end

    assign(socket, :current_user, user)
  end
end

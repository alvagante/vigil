defmodule VigilWeb.SessionPlugTest do
  use VigilWeb.LiveCase, async: true

  alias Plug.Conn
  alias Vigil.Core.Accounts
  alias VigilWeb.SessionPlug

  defp build_conn_with_session(nil) do
    Phoenix.ConnTest.build_conn()
    |> Conn.put_private(:plug_session_fetch, :done)
    |> Conn.put_private(:plug_session, %{})
  end

  defp build_conn_with_session(token) do
    Phoenix.ConnTest.build_conn()
    |> Conn.put_private(:plug_session_fetch, :done)
    |> Conn.put_private(:plug_session, %{"_vigil_token" => token})
  end

  setup do
    {:ok, user} =
      Accounts.register_user(%{username: "plug_test_user", password: "plug_test_password!"})

    {:ok, token, _session} = Accounts.create_session(user)
    %{user: user, token: token}
  end

  test "assigns current_user when a valid session token is present", %{user: user, token: token} do
    conn = build_conn_with_session(token) |> SessionPlug.call([])
    assert conn.assigns[:current_user] != nil
    assert conn.assigns[:current_user].id == user.id
  end

  test "does not assign current_user when no token is present" do
    conn = build_conn_with_session(nil) |> SessionPlug.call([])
    refute conn.assigns[:current_user]
  end

  test "does not assign current_user for an unknown token" do
    conn = build_conn_with_session("fake_invalid_token_value") |> SessionPlug.call([])
    refute conn.assigns[:current_user]
  end
end

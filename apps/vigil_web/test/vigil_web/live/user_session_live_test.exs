defmodule VigilWeb.Live.UserSessionLiveTest do
  use VigilWeb.LiveCase, async: true

  describe "login page" do
    test "renders login form for unauthenticated user", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users/log_in")
      assert html =~ "Log in"
      assert html =~ ~s(name="username")
      assert html =~ ~s(name="password")
    end

    test "redirects authenticated user to /", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/users/log_in")
    end
  end
end

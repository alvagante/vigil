defmodule VigilWeb.UserSessionControllerTest do
  use VigilWeb.LiveCase, async: true

  import Ecto.Query

  alias Vigil.Repo
  alias Vigil.Core.{RBAC, Audit.Entry}
  alias Vigil.Core.Accounts.User

  describe "user_fixture/1" do
    test "default fixture user passes RBAC.check for any action" do
      user = user_fixture()
      assert :ok = RBAC.check(user, "ssh:command:execute", %RBAC.Context{})
      assert :ok = RBAC.check(user, "platform:admin", %RBAC.Context{})
    end

    test "fixture user with role: :none is denied all actions" do
      user = user_fixture(%{role: :none})
      assert {:error, :denied} = RBAC.check(user, "ssh:command:execute", %RBAC.Context{})
    end
  end

  describe "POST /users/log_in" do
    test "valid credentials create session and redirect to /", %{conn: conn} do
      user = user_fixture()
      conn = post(conn, ~p"/users/log_in", %{username: user.username, password: "test_password_123!"})
      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, "_vigil_token")
    end

    test "successful login writes an auth.login audit entry", %{conn: conn} do
      user = user_fixture()
      post(conn, ~p"/users/log_in", %{username: user.username, password: "test_password_123!"})

      entry = Repo.one!(from e in Entry, where: e.action == "auth.login" and e.actor_user_id == ^user.id)
      assert entry.result == "success"
    end

    test "break-glass login writes auth.login.break_glass with params.break_glass=true", %{conn: conn} do
      user = user_fixture()
      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [is_break_glass: true])
      user = Repo.get!(User, user.id)

      post(conn, ~p"/users/log_in", %{username: user.username, password: "test_password_123!"})

      entry = Repo.one!(from e in Entry, where: e.action == "auth.login.break_glass")
      assert entry.result == "success"
      assert entry.params["break_glass"] == true
    end

    test "invalid credentials redirect back with error flash", %{conn: conn} do
      conn = post(conn, ~p"/users/log_in", %{username: "nobody", password: "wrongpassword123!"})
      assert redirected_to(conn) == ~p"/users/log_in"
      refute get_session(conn, "_vigil_token")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid"
    end

    test "failed login writes an auth.login audit entry with failure result", %{conn: conn} do
      post(conn, ~p"/users/log_in", %{username: "nobody", password: "wrongpassword123!"})

      entry = Repo.one!(from e in Entry, where: e.action == "auth.login" and e.actor_label == "nobody")
      assert entry.result == "failure"
    end
  end

  describe "DELETE /users/log_out" do
    test "clears session and redirects to /users/log_in", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      assert get_session(conn, "_vigil_token")

      conn = delete(conn, ~p"/users/log_out")
      assert redirected_to(conn) == ~p"/users/log_in"
      refute get_session(conn, "_vigil_token")
    end

    test "logout writes an auth.logout audit entry", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      delete(conn, ~p"/users/log_out")

      entry = Repo.one!(from e in Entry, where: e.action == "auth.logout" and e.actor_user_id == ^user.id)
      assert entry.result == "success"
    end
  end
end

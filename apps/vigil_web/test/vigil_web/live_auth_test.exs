defmodule VigilWeb.LiveAuthTest do
  use VigilWeb.LiveCase, async: true

  alias Vigil.Core.{Accounts, RBAC}
  alias VigilWeb.LiveAuth

  @session_key "_vigil_token"

  defp bare_socket, do: %Phoenix.LiveView.Socket{}

  defp session_for(user) do
    {:ok, token, _} = Accounts.create_session(user)
    %{@session_key => token}
  end

  # ── Cycle 4: mount_current_user assigns user from valid token ─────────────

  describe "mount_current_user" do
    test "assigns user from a valid session token" do
      user = user_fixture()

      {:cont, socket} =
        LiveAuth.on_mount(:mount_current_user, %{}, session_for(user), bare_socket())

      assert socket.assigns[:current_user].id == user.id
    end

    test "assigns nil when no token in session" do
      {:cont, socket} = LiveAuth.on_mount(:mount_current_user, %{}, %{}, bare_socket())

      assert socket.assigns[:current_user] == nil
    end

    test "assigns nil for an invalid token" do
      {:cont, socket} =
        LiveAuth.on_mount(
          :mount_current_user,
          %{},
          %{@session_key => "not_a_real_token"},
          bare_socket()
        )

      assert socket.assigns[:current_user] == nil
    end
  end

  # ── Cycle 5-6: require_authenticated ─────────────────────────────────────

  describe "require_authenticated" do
    test "returns {:cont, socket} when session contains a valid user" do
      user = user_fixture()

      assert {:cont, socket} =
               LiveAuth.on_mount(:require_authenticated, %{}, session_for(user), bare_socket())

      assert socket.assigns[:current_user].id == user.id
    end

    test "returns {:halt, socket} when no session token is present" do
      assert {:halt, socket} =
               LiveAuth.on_mount(:require_authenticated, %{}, %{}, bare_socket())

      assert socket.redirected == {:redirect, %{status: 302, to: "/users/log_in"}}
    end

    test "returns {:halt, socket} for an invalid token" do
      session = %{@session_key => "invalid_token_value"}

      assert {:halt, socket} =
               LiveAuth.on_mount(:require_authenticated, %{}, session, bare_socket())

      assert socket.redirected == {:redirect, %{status: 302, to: "/users/log_in"}}
    end
  end

  # ── Cycle 7: require_authenticated via router ─────────────────────────────

  describe "require_authenticated (router integration)" do
    test "unauthenticated request is redirected to /users/log_in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/")
    end

    test "authenticated user can mount the live view", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      assert {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Vigil"
    end
  end

  # ── Cycle 8-9: require_permission ─────────────────────────────────────────

  describe "{:require_permission, action}" do
    test "returns {:cont, socket} when user has the required permission" do
      user = user_fixture()
      {:ok, role} = RBAC.create_role(%{name: "live_auth_role_#{System.unique_integer()}"})
      {:ok, _} = RBAC.grant_permission(role, %{action: "ssh:command:execute"})
      :ok = RBAC.assign_role(user, role, source: "direct")

      assert {:cont, _socket} =
               LiveAuth.on_mount(
                 {:require_permission, "ssh:command:execute"},
                 %{},
                 session_for(user),
                 bare_socket()
               )
    end

    test "returns {:halt, socket} when user lacks the required permission" do
      user = user_fixture(%{role: :none})

      assert {:halt, socket} =
               LiveAuth.on_mount(
                 {:require_permission, "ssh:command:execute"},
                 %{},
                 session_for(user),
                 bare_socket()
               )

      assert socket.redirected == {:redirect, %{status: 302, to: "/"}}
    end

    test "returns {:halt, socket} redirecting to log_in when unauthenticated" do
      assert {:halt, socket} =
               LiveAuth.on_mount(
                 {:require_permission, "ssh:command:execute"},
                 %{},
                 %{},
                 bare_socket()
               )

      assert socket.redirected == {:redirect, %{status: 302, to: "/users/log_in"}}
    end
  end

  # ── Cycle 10: router permission gates on operational routes ───────────────

  describe "require_permission (router integration)" do
    test "user with role:none is denied /inventory (redirected to /)", %{conn: conn} do
      user = user_fixture(%{role: :none})
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/inventory")
    end

    test "user with role:none is denied /health (redirected to /)", %{conn: conn} do
      user = user_fixture(%{role: :none})
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/health")
    end

    test "user with role:none is denied /executions (redirected to /)", %{conn: conn} do
      user = user_fixture(%{role: :none})
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/executions")
    end

    test "user with role:none is denied /executions/new (redirected to /)", %{conn: conn} do
      user = user_fixture(%{role: :none})
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/executions/new")
    end

    test "user with inventory:node:read can access /inventory", %{conn: conn} do
      user = user_fixture(%{role: :none})
      {:ok, role} = RBAC.create_role(%{name: "inv_test_#{System.unique_integer()}"})
      {:ok, _} = RBAC.grant_permission(role, %{action: "inventory:node:read"})
      :ok = RBAC.assign_role(user, role)
      conn = log_in_user(conn, user)

      assert {:ok, _view, _html} = live(conn, ~p"/inventory")
    end

    test "user with integration:health:read can access /health", %{conn: conn} do
      user = user_fixture(%{role: :none})
      {:ok, role} = RBAC.create_role(%{name: "health_test_#{System.unique_integer()}"})
      {:ok, _} = RBAC.grant_permission(role, %{action: "integration:health:read"})
      :ok = RBAC.assign_role(user, role)
      conn = log_in_user(conn, user)

      assert {:ok, _view, _html} = live(conn, ~p"/health")
    end

    test "user with execution:read can access /executions", %{conn: conn} do
      user = user_fixture(%{role: :none})
      {:ok, role} = RBAC.create_role(%{name: "exec_test_#{System.unique_integer()}"})
      {:ok, _} = RBAC.grant_permission(role, %{action: "execution:read"})
      :ok = RBAC.assign_role(user, role)
      conn = log_in_user(conn, user)

      assert {:ok, _view, _html} = live(conn, ~p"/executions")
    end

    test "user with execution:submit can access /executions/new", %{conn: conn} do
      user = user_fixture(%{role: :none})
      {:ok, role} = RBAC.create_role(%{name: "exec_submit_test_#{System.unique_integer()}"})
      {:ok, _} = RBAC.grant_permission(role, %{action: "execution:submit"})
      :ok = RBAC.assign_role(user, role)
      conn = log_in_user(conn, user)

      assert {:ok, _view, _html} = live(conn, ~p"/executions/new")
    end
  end
end

defmodule VigilWeb.Live.Settings.RolesLiveTest do
  use VigilWeb.LiveCase, async: false

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  describe "roles list" do
    test "renders all built-in roles", %{conn: conn} do
      Vigil.Core.Seeds.seed()
      {:ok, _view, html} = live(conn, ~p"/settings/roles")
      assert html =~ "administrator"
      assert html =~ "operator"
      assert html =~ "read-only"
      assert html =~ "auditor"
      assert html =~ "mcp-service"
    end

    test "shows existing permissions for a role", %{conn: conn} do
      {:ok, role} = Vigil.Core.RBAC.create_role(%{name: "test_role_perms"})
      {:ok, _} = Vigil.Core.RBAC.grant_permission(role, %{action: "ssh:node:read"})

      {:ok, _view, html} = live(conn, ~p"/settings/roles")
      assert html =~ "ssh:node:read"
    end

    test "admin can grant a new permission to a role", %{conn: conn} do
      {:ok, role} = Vigil.Core.RBAC.create_role(%{name: "grant_target_role"})

      {:ok, view, _html} = live(conn, ~p"/settings/roles")

      view
      |> form("[data-role-id=\"#{role.id}\"] form[phx-submit=\"grant_permission\"]",
        permission: %{action: "bolt:task:run"}
      )
      |> render_submit()

      assert render(view) =~ "bolt:task:run"
    end

    test "admin can assign a role to a user", %{conn: conn} do
      {:ok, role} = Vigil.Core.RBAC.create_role(%{name: "assignable_role"})
      target_user = user_fixture(%{role: :none})

      {:ok, view, _html} = live(conn, ~p"/settings/roles")

      view
      |> form("[data-role-id=\"#{role.id}\"] form[phx-submit=\"assign_role\"]",
        assignment: %{username: target_user.username}
      )
      |> render_submit()

      assert render(view) =~ target_user.username
    end

    test "user without platform:admin is redirected" do
      unprivileged_conn = log_in_user(Phoenix.ConnTest.build_conn(), user_fixture(%{role: :none}))
      assert {:error, {:redirect, %{to: "/"}}} = live(unprivileged_conn, ~p"/settings/roles")
    end
  end
end

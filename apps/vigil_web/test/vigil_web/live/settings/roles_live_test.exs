defmodule VigilWeb.Live.Settings.RolesLiveTest do
  use VigilWeb.LiveCase, async: false

  import Ecto.Query
  alias Vigil.Repo
  alias Vigil.Core.Audit.Entry

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

    test "granting a permission writes an rbac.permission.grant audit entry", %{
      conn: conn,
      user: admin
    } do
      {:ok, role} = Vigil.Core.RBAC.create_role(%{name: "audit_grant_role"})
      {:ok, view, _html} = live(conn, ~p"/settings/roles")

      view
      |> form("[data-role-id=\"#{role.id}\"] form[phx-submit=\"grant_permission\"]",
        permission: %{action: "ssh:node:read"}
      )
      |> render_submit()

      entry =
        Repo.one!(
          from(e in Entry,
            where: e.action == "rbac.permission.grant" and e.actor_user_id == ^admin.id
          )
        )

      assert entry.result == "success"
      assert entry.params["permission_action"] == "ssh:node:read"
    end

    test "assigning a role writes an rbac.role.assign audit entry", %{conn: conn, user: admin} do
      {:ok, role} = Vigil.Core.RBAC.create_role(%{name: "audit_assign_role"})
      target = user_fixture(%{role: :none})
      {:ok, view, _html} = live(conn, ~p"/settings/roles")

      view
      |> form("[data-role-id=\"#{role.id}\"] form[phx-submit=\"assign_role\"]",
        assignment: %{username: target.username}
      )
      |> render_submit()

      entry =
        Repo.one!(
          from(e in Entry, where: e.action == "rbac.role.assign" and e.actor_user_id == ^admin.id)
        )

      assert entry.result == "success"
      assert entry.params["username"] == target.username
    end

    test "admin can create a new role", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/roles")

      view
      |> form("form[phx-submit=\"create_role\"]", role: %{name: "new-custom-role"})
      |> render_submit()

      assert render(view) =~ "new-custom-role"
    end

    test "user without platform:admin is redirected" do
      unprivileged_conn = log_in_user(Phoenix.ConnTest.build_conn(), user_fixture(%{role: :none}))
      assert {:error, {:redirect, %{to: "/"}}} = live(unprivileged_conn, ~p"/settings/roles")
    end
  end
end

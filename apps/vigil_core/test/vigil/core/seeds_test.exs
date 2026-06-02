defmodule Vigil.Core.SeedsTest do
  use Vigil.DataCase, async: false

  import Ecto.Query

  alias Vigil.Repo
  alias Vigil.Core.{Seeds, RBAC, Accounts}
  alias Vigil.Core.Accounts.User
  alias Vigil.Core.RBAC.{Role, UserRole, RolePermission}

  describe "seed/0" do
    test "creates the break-glass admin user" do
      Seeds.seed()
      admin = Repo.one!(from u in User, where: u.is_break_glass == true)
      assert admin.username == "admin"
      assert admin.auth_source == "local"
      assert admin.status == "active"
    end

    test "creates the five default built-in roles" do
      Seeds.seed()
      names = Repo.all(from r in Role, where: r.built_in == true, select: r.name)
      assert "administrator" in names
      assert "operator" in names
      assert "read-only" in names
      assert "auditor" in names
      assert "mcp-service" in names
    end

    test "assigns the administrator role to the break-glass admin" do
      Seeds.seed()
      admin = Repo.one!(from u in User, where: u.is_break_glass == true)
      admin_role = Repo.one!(from r in Role, where: r.name == "administrator")

      assert Repo.exists?(
               from ur in UserRole,
                 where: ur.user_id == ^admin.id and ur.role_id == ^admin_role.id
             )
    end

    test "grants wildcard permission \"*\" to the administrator role" do
      Seeds.seed()
      admin_role = Repo.one!(from r in Role, where: r.name == "administrator")

      assert Repo.exists?(
               from rp in RolePermission,
                 where: rp.role_id == ^admin_role.id and rp.action == "*"
             )
    end

    test "seeded break-glass admin passes RBAC.check for any action" do
      Seeds.seed()
      admin = Repo.one!(from u in User, where: u.is_break_glass == true)

      assert :ok = RBAC.check(admin, "ssh:command:execute", %RBAC.Context{})
      assert :ok = RBAC.check(admin, "rbac:role:update", %RBAC.Context{})
      assert :ok = RBAC.check(admin, "platform:admin", %RBAC.Context{})
    end

    test "is idempotent — calling twice produces one admin and five roles" do
      Seeds.seed()
      Seeds.seed()

      admin_count = Repo.aggregate(from(u in User, where: u.is_break_glass == true), :count)
      role_count = Repo.aggregate(from(r in Role, where: r.built_in == true), :count)
      assert admin_count == 1
      assert role_count == 5
    end

    test "operator role has read and execute permissions" do
      Seeds.seed()
      role = Repo.one!(from r in Role, where: r.name == "operator")
      actions = Repo.all(from rp in RolePermission, where: rp.role_id == ^role.id, select: rp.action)

      assert "inventory:node:read" in actions
      assert "integration:health:read" in actions
      assert "execution:read" in actions
      assert "execution:submit" in actions
    end

    test "read-only role has read-only permissions and no submit" do
      Seeds.seed()
      role = Repo.one!(from r in Role, where: r.name == "read-only")
      actions = Repo.all(from rp in RolePermission, where: rp.role_id == ^role.id, select: rp.action)

      assert "inventory:node:read" in actions
      assert "integration:health:read" in actions
      assert "execution:read" in actions
      refute "execution:submit" in actions
    end

    test "auditor role has health and audit permissions only" do
      Seeds.seed()
      role = Repo.one!(from r in Role, where: r.name == "auditor")
      actions = Repo.all(from rp in RolePermission, where: rp.role_id == ^role.id, select: rp.action)

      assert "integration:health:read" in actions
      assert "audit:entry:read" in actions
      refute "inventory:node:read" in actions
      refute "execution:submit" in actions
    end

    test "mcp-service role has inventory read only" do
      Seeds.seed()
      role = Repo.one!(from r in Role, where: r.name == "mcp-service")
      actions = Repo.all(from rp in RolePermission, where: rp.role_id == ^role.id, select: rp.action)

      assert "inventory:node:read" in actions
      refute "execution:submit" in actions
    end

    test "seeded read-only role passes RBAC.check for inventory:node:read" do
      Seeds.seed()
      read_only_role = Repo.one!(from r in Role, where: r.name == "read-only")

      {:ok, user} = Accounts.register_user(%{username: "test_readonly_#{System.unique_integer()}", password: "test_password_123!"})
      :ok = RBAC.assign_role(user, read_only_role)

      assert :ok = RBAC.check(user, "inventory:node:read", %RBAC.Context{})
      assert {:error, :denied} = RBAC.check(user, "execution:submit", %RBAC.Context{})
    end

    test "seeded built-in role permissions are idempotent" do
      Seeds.seed()
      Seeds.seed()

      role = Repo.one!(from r in Role, where: r.name == "operator")
      count = Repo.aggregate(from(rp in RolePermission, where: rp.role_id == ^role.id), :count)
      assert count == 4
    end
  end
end

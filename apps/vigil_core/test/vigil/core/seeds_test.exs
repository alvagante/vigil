defmodule Vigil.Core.SeedsTest do
  use Vigil.DataCase, async: false

  import Ecto.Query

  alias Vigil.Repo
  alias Vigil.Core.Seeds
  alias Vigil.Core.Accounts.User
  alias Vigil.Core.RBAC.{Role, UserRole}

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

    test "is idempotent — calling twice produces one admin and five roles" do
      Seeds.seed()
      Seeds.seed()

      admin_count = Repo.aggregate(from(u in User, where: u.is_break_glass == true), :count)
      role_count = Repo.aggregate(from(r in Role, where: r.built_in == true), :count)
      assert admin_count == 1
      assert role_count == 5
    end
  end
end

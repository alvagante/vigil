defmodule Vigil.Core.Seeds do
  @moduledoc false

  import Ecto.Query

  alias Vigil.Repo
  alias Vigil.Core.Accounts.User
  alias Vigil.Core.RBAC.{Role, RolePermission, UserRole}

  @default_tenant_id "00000000-0000-0000-0000-000000000000"

  @roles [
    %{name: "administrator", description: "Full access to all capabilities.", built_in: true},
    %{name: "operator", description: "Read all; execute on integrations; no destructive provisioning.", built_in: true},
    %{name: "read-only", description: "Read-only on everything.", built_in: true},
    %{name: "auditor", description: "Read-only on journal, audit trail, and integration health.", built_in: true},
    %{name: "mcp-service", description: "Read-only MCP tools for AI service accounts.", built_in: true}
  ]

  @built_in_permissions %{
    "operator" => ["inventory:node:read", "integration:health:read", "execution:read", "execution:submit"],
    "read-only" => ["inventory:node:read", "integration:health:read", "execution:read"],
    "auditor" => ["integration:health:read", "audit:entry:read"],
    "mcp-service" => ["inventory:node:read"]
  }

  def seed do
    Repo.transaction(fn ->
      roles = upsert_roles()
      admin = upsert_break_glass_admin()
      grant_administrator_wildcard(roles["administrator"])
      grant_built_in_role_permissions(roles)
      assign_admin_role(admin, roles["administrator"])
    end)

    :ok
  end

  defp upsert_roles do
    Enum.reduce(@roles, %{}, fn attrs, acc ->
      role =
        case Repo.one(from r in Role, where: r.name == ^attrs.name and r.tenant_id == ^@default_tenant_id) do
          nil ->
            %Role{}
            |> Role.changeset(attrs)
            |> Repo.insert!()

          existing ->
            existing
        end

      Map.put(acc, attrs.name, role)
    end)
  end

  defp upsert_break_glass_admin do
    case Repo.one(from u in User, where: u.is_break_glass == true and u.tenant_id == ^@default_tenant_id) do
      nil ->
        password = generate_password()
        IO.puts("\n[vigil seeds] Break-glass admin created. Username: admin  Password: #{password}")
        IO.puts("[vigil seeds] Rotate this password before going to production.\n")

        %User{tenant_id: @default_tenant_id, is_break_glass: true}
        |> User.registration_changeset(%{username: "admin", password: password})
        |> Repo.insert!()

      existing ->
        existing
    end
  end

  defp grant_built_in_role_permissions(roles) do
    for {role_name, actions} <- @built_in_permissions,
        role = Map.get(roles, role_name),
        action <- actions do
      already_granted =
        Repo.exists?(
          from rp in RolePermission,
            where: rp.role_id == ^role.id and rp.action == ^action and is_nil(rp.integration_id)
        )

      unless already_granted do
        %RolePermission{}
        |> RolePermission.changeset(%{role_id: role.id, action: action})
        |> Repo.insert!()
      end
    end
  end

  defp grant_administrator_wildcard(role) do
    %RolePermission{}
    |> RolePermission.changeset(%{role_id: role.id, action: "*"})
    |> Repo.insert(on_conflict: :nothing)
  end

  defp assign_admin_role(user, role) do
    %UserRole{}
    |> UserRole.changeset(%{
      user_id: user.id,
      role_id: role.id,
      source: "seed",
      assigned_at: DateTime.utc_now()
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  defp generate_password do
    :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
  end
end

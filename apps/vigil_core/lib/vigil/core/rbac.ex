defmodule Vigil.Core.RBAC do
  import Ecto.Query
  alias Vigil.Repo
  alias Vigil.Core.RBAC.{Role, RolePermission, UserRole, Evaluator}

  defdelegate check(principal, action, context), to: Evaluator

  def list_roles do
    Repo.all(
      from r in Role,
        order_by: [asc: r.name],
        preload: [:role_permissions, user_roles: :user]
    )
  end

  def list_permissions_for(role) do
    Repo.all(from rp in RolePermission, where: rp.role_id == ^role.id)
  end

  def revoke_permission(permission_id) do
    case Repo.get(RolePermission, permission_id) do
      nil -> {:error, :not_found}
      perm -> Repo.delete(perm)
    end
  end

  def create_role(attrs) do
    %Role{}
    |> Role.changeset(attrs)
    |> Repo.insert()
  end

  def grant_permission(role, attrs) do
    %RolePermission{}
    |> RolePermission.changeset(Map.put(attrs, :role_id, role.id))
    |> Repo.insert()
  end

  def assign_role(user, role, opts \\ []) do
    source = Keyword.get(opts, :source, "direct")

    %UserRole{}
    |> UserRole.changeset(%{
      user_id: user.id,
      role_id: role.id,
      source: source,
      assigned_at: DateTime.utc_now()
    })
    |> Repo.insert(on_conflict: :nothing)
    |> case do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end

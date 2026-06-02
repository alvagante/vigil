defmodule Vigil.Core.RBAC do
  alias Vigil.Repo
  alias Vigil.Core.RBAC.{Role, RolePermission, UserRole, Evaluator}

  defdelegate check(principal, action, context), to: Evaluator

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

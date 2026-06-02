defmodule Vigil.Core.RBAC.Evaluator do
  import Ecto.Query
  alias Vigil.Repo
  alias Vigil.Core.RBAC.{RolePermission, UserRole}

  def check(principal, action, context) do
    principal.id
    |> effective_permissions(action)
    |> Enum.any?(&permits?(&1, context))
    |> case do
      true -> :ok
      false -> {:error, :denied}
    end
  end

  # Two DB queries total, regardless of target count in context.
  defp effective_permissions(principal_id, action) do
    role_ids =
      from(ur in UserRole, where: ur.user_id == ^principal_id, select: ur.role_id)
      |> Repo.all()

    from(rp in RolePermission,
      where: rp.role_id in ^role_ids and (rp.action == ^action or rp.action == "*")
    )
    |> Repo.all()
  end

  defp permits?(permission, context) do
    integration_matches?(permission, context.integration_id) and
      target_matches?(permission, context.resolved_targets)
  end

  defp integration_matches?(%{integration_id: nil}, _), do: true
  defp integration_matches?(%{integration_id: perm_id}, ctx_id), do: perm_id == ctx_id

  # Pure function — no DB. O(targets) but zero queries.
  defp target_matches?(%{target_selector: nil}, _), do: true
  defp target_matches?(%{target_selector: sel}, targets) when is_list(targets) do
    Enum.all?(targets, &node_in_selector?(&1, sel))
  end

  defp node_in_selector?(_node, sel) when map_size(sel) == 0, do: true

  defp node_in_selector?(node, %{"tags" => tag_filter}) do
    tags = Map.get(node, :tags, %{})
    Enum.all?(tag_filter, fn {k, vs} -> Map.get(tags, k) in List.wrap(vs) end)
  end

  defp node_in_selector?(_node, _sel), do: true
end

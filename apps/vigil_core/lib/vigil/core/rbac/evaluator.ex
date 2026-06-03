defmodule Vigil.Core.RBAC.Evaluator do
  import Ecto.Query
  alias Vigil.Repo
  alias Vigil.Core.RBAC.{GlobPolicy, RolePermission, UserRole}

  def check(principal, action, context) do
    principal.id
    |> effective_permissions(action)
    |> Enum.any?(&permits?(&1, context))
    |> case do
      true -> :ok
      false -> {:error, :denied}
    end
  end

  @doc """
  Partitions `context.resolved_targets` into `{permitted, denied}`.

  Loads the principal's permissions **once** (2 DB queries) then evaluates
  each target in-memory — constant query count regardless of target count
  (TEST-202 / RBAC-108 invariant). ADR-0005 DM-601 shape.
  """
  def partition(principal, action, context) do
    permissions = effective_permissions(principal.id, action)

    Enum.split_with(context.resolved_targets, fn target ->
      single_ctx = %{context | resolved_targets: [target]}
      Enum.any?(permissions, &permits?(&1, single_ctx))
    end)
  end

  @doc """
  Filters `nodes` to those visible to `principal` under `"inventory:node:read"`.

  Loads the principal's effective permissions **once** (2 DB queries) then
  evaluates each node in-memory — O(permissions × nodes), zero additional
  queries (RBAC-107, RBAC-108, ADR-0006). Respects both `integration_id`
  scoping and `target_selector` tag-matching on each permission.
  """
  def filter_targets(nodes, principal, integration_id) do
    permissions = effective_permissions(principal.id, "inventory:node:read")

    Enum.filter(nodes, fn node ->
      Enum.any?(permissions, fn perm ->
        integration_matches?(perm, integration_id) and
          node_in_selector?(node, perm.target_selector || %{})
      end)
    end)
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
      target_matches?(permission, context.resolved_targets) and
      command_matches?(permission.command_policy, context.artifact)
  end

  defp command_matches?(policy, artifact) do
    command = artifact_to_command_string(artifact)
    GlobPolicy.matches?(policy, command)
  end

  defp artifact_to_command_string(nil), do: ""
  defp artifact_to_command_string(%{text: t}) when is_binary(t), do: t
  defp artifact_to_command_string(%{"text" => t}) when is_binary(t), do: t
  defp artifact_to_command_string(_), do: ""

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

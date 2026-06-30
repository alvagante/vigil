defmodule Vigil.Core.Executions do
  @moduledoc """
  Core execution context: submission pipeline, history queries, re-run helpers.

  `submit/2` accepts a `runner_module:` key so callers at the plugin layer
  (where `Vigil.Plugin.Catalog` is available) can resolve the module before
  calling here. This keeps `vigil_core` free of plugin-discovery dependencies.

  ## Known deferrals
  - **ROAD-104 audit-first ordering** — a minimal audit log is written per
    submission. The full audit pipeline (Audit.write_pending/finalize) lands
    in #8 with the RBAC infrastructure.
  """

  alias Vigil.Core.Audit
  alias Vigil.Core.Execution.{Group, Record, Supervisor}
  alias Vigil.Core.RBAC
  alias Vigil.Core.RBAC.Context, as: RBACContext
  alias Vigil.Repo

  @doc """
  Submits an execution request.

  Required keys in `params`:
    - `:runner_module` — module implementing `Vigil.Plugin.Execution.Runner`
    - `:integration_id` — string ID of the integration
    - `:artifact` — `%{kind: :command, text: "..."}` (or task/plan variants)
    - `:targets` — `%{node_ids: [string]}` (groups/filter deferred)

  Returns `{:ok, execution_group_id}` or `{:error, reason}`.
  """
  def submit(principal, params) do
    %{
      runner_module: runner_module,
      integration_id: integration_id,
      artifact: artifact,
      targets: targets_param
    } = params

    node_ids = targets_param.node_ids
    timeout = Map.get(params, :timeout, %{})
    now = DateTime.utc_now()

    # RBAC partition (ADR-0005): when permission_action is given, split
    # targets into permitted / denied before touching the DB.
    {permitted_ids, denied_ids} =
      rbac_partition(principal, params, integration_id, artifact, node_ids)

    if permitted_ids == [] do
      Audit.write_finalized(principal, "execution.submit", :denied,
        target_kind: "execution_submit",
        params: %{
          integration_id: integration_id,
          node_ids: node_ids,
          denied_node_ids: denied_ids,
          permitted_count: 0
        }
      )

      {:error, :all_denied}
    else
      result =
        Repo.transaction(fn ->
          group =
            Repo.insert!(%Group{
              integration_id: integration_id,
              artifact: artifact,
              intended_targets: %{node_ids: node_ids},
              dispatched_count: length(permitted_ids),
              submitted_by: to_string(principal.id),
              submitted_at: now
            })

          run_targets =
            Enum.map(permitted_ids, fn node_id ->
              record =
                Repo.insert!(%Record{
                  execution_group_id: group.id,
                  integration_id: integration_id,
                  node_id: node_id,
                  artifact: artifact,
                  outcome: "running",
                  streaming_state: "live",
                  started_at: now
                })

              %{execution_id: record.id, node_id: node_id}
            end)

          {:ok, audit_pending} =
            Audit.write_pending(principal, "execution.submit",
              target_kind: "execution_group",
              target_id: group.id,
              params: %{
                integration_id: integration_id,
                node_ids: permitted_ids,
                denied_node_ids: denied_ids
              }
            )

          {group, run_targets, audit_pending}
        end)

      case result do
        {:ok, {group, run_targets, audit_pending}} ->
          case Supervisor.start_stream(%{
                 runner_module: runner_module,
                 integration_id: integration_id,
                 artifact: artifact,
                 group_id: group.id,
                 targets: run_targets,
                 timeout: timeout
               }) do
            {:ok, _pid} ->
              Audit.finalize(audit_pending, :success)
              {:ok, group.id}

            {:error, reason} ->
              Audit.finalize(audit_pending, :failure)
              {:error, reason}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp rbac_partition(principal, params, integration_id, artifact, node_ids) do
    case Map.get(params, :permission_action) do
      nil ->
        {node_ids, []}

      action ->
        resolved =
          get_in(params, [:targets, :resolved]) ||
            Enum.map(node_ids, fn id -> %{id: id} end)

        context = %RBACContext{
          integration_id: integration_id,
          resolved_targets: resolved,
          artifact: artifact
        }

        {permitted, denied} = RBAC.partition(principal, action, context)
        {Enum.map(permitted, & &1.id), Enum.map(denied, & &1.id)}
    end
  end

  @doc """
  Re-runs a single target from an existing `execution_id`. Submits a new
  single-target group with the same artifact and node_id (RBAC is re-evaluated
  at submit time per ADR-0005 — this is the plugin layer's responsibility).
  """
  def rerun_record(execution_id, principal, runner_module, opts \\ %{}) do
    with {:ok, record} <- get_record(execution_id) do
      submit(principal, %{
        runner_module: runner_module,
        integration_id: record.integration_id,
        artifact: record.artifact,
        targets: %{node_ids: [record.node_id]},
        timeout: Map.get(opts, :timeout, %{})
      })
    end
  end

  @doc """
  Re-runs all targets from an existing `execution_group_id`. Uses
  `intended_targets` from the group so denied targets are included in the
  new RBAC evaluation.
  """
  def rerun_group(group_id, principal, runner_module, opts \\ %{}) do
    import Ecto.Query

    with group when not is_nil(group) <-
           Repo.get(Group, group_id) || {:error, :not_found} do
      node_ids =
        Repo.all(from(r in Record, where: r.execution_group_id == ^group_id, select: r.node_id))

      submit(principal, %{
        runner_module: runner_module,
        integration_id: group.integration_id,
        artifact: group.artifact,
        targets: %{node_ids: node_ids},
        timeout: Map.get(opts, :timeout, %{})
      })
    end
  end

  @doc "Returns the execution record for a given `execution_id`."
  def get_record(execution_id) do
    case Repo.get(Record, execution_id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @doc "Returns the execution group for a given `group_id`."
  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :not_found}
      group -> {:ok, group}
    end
  end

  @doc "Returns all execution groups, ordered by submission time descending."
  def history(filters \\ %{}) do
    import Ecto.Query

    query =
      from(g in Group,
        order_by: [desc: g.submitted_at],
        preload: :executions
      )

    query =
      if node_id = filters[:node_id] do
        matching_groups =
          from(e in Record,
            where: e.node_id == ^node_id,
            select: e.execution_group_id
          )

        from(g in query, where: g.id in subquery(matching_groups))
      else
        query
      end

    query =
      if outcome = filters[:outcome] do
        matching_groups =
          from(e in Record,
            where: e.outcome == ^outcome,
            select: e.execution_group_id
          )

        from(g in query, where: g.id in subquery(matching_groups))
      else
        query
      end

    Repo.all(query)
  end
end

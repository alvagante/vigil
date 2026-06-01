defmodule Vigil.Plugin.Executions do
  @moduledoc """
  Plugin-layer execution gateway. Resolves the runner module for an
  integration from the Registry, then delegates to `Vigil.Core.Executions`.

  This module sits between the UI layer (which knows integration_id and artifact)
  and the core (which needs a concrete runner_module). The split keeps
  `vigil_core` free of plugin-discovery code.
  """

  alias Vigil.Plugin.Error

  @doc """
  Submit an execution. Resolves the runner_module via the plugin Registry,
  then calls `Vigil.Core.Executions.submit/2`.

  Required keys in `params`:
    - `:integration_id`
    - `:artifact` — `%{kind: :command, text: "..."}`
    - `:targets` — `%{node_ids: [string]}`
  """
  def submit(principal, params) do
    integration_id = params.integration_id

    case Registry.lookup(Vigil.Plugin.Registry, {:integration, integration_id}) do
      [{_pid, plugin_module}] ->
        Vigil.Core.Executions.submit(principal, Map.put(params, :runner_module, plugin_module))

      [] ->
        {:error,
         %Error{
           category: :configuration,
           message: "no running plugin for integration #{inspect(integration_id)}",
           retriable?: false
         }}
    end
  end

  @doc """
  Re-runs a single execution record. Resolves the runner_module from the
  original execution's integration_id, then delegates to Core.
  """
  def rerun_record(execution_id, principal, opts \\ %{}) do
    with {:ok, record} <- Vigil.Core.Executions.get_record(execution_id) do
      case Registry.lookup(Vigil.Plugin.Registry, {:integration, record.integration_id}) do
        [{_pid, plugin_module}] ->
          Vigil.Core.Executions.rerun_record(execution_id, principal, plugin_module, opts)

        [] ->
          {:error,
           %Error{
             category: :configuration,
             message: "no running plugin for integration #{inspect(record.integration_id)}",
             retriable?: false
           }}
      end
    end
  end

  @doc """
  Re-runs all targets from an execution group. Resolves runner_module from
  the group's integration_id.
  """
  def rerun_group(group_id, principal, opts \\ %{}) do
    case Vigil.Core.Executions.get_group(group_id) do
      {:ok, group} ->
        case Registry.lookup(Vigil.Plugin.Registry, {:integration, group.integration_id}) do
          [{_pid, plugin_module}] ->
            Vigil.Core.Executions.rerun_group(group_id, principal, plugin_module, opts)

          [] ->
            {:error,
             %Error{
               category: :configuration,
               message: "no running plugin for integration #{inspect(group.integration_id)}",
               retriable?: false
             }}
        end

      {:error, _} = err ->
        err
    end
  end
end

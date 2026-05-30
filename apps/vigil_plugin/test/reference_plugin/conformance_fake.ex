defmodule Vigil.Plugin.ConformanceFake do
  @moduledoc """
  Test-support plugin that conforms to the full contract (by delegating to
  `Vigil.Plugin.NoOp`) but declares an extra `:facts` capability for which no
  conformance contract exists yet. Used to prove the suite flags uncontracted
  capabilities as warnings rather than passing silently (ROAD-105).
  """

  @behaviour Vigil.Plugin
  @behaviour Vigil.Plugin.Health
  @behaviour Vigil.Plugin.Inventory
  @behaviour Vigil.Plugin.Execution.Runner

  alias Vigil.Plugin.NoOp

  @impl Vigil.Plugin
  def capabilities, do: [:inventory, :execution, :facts]

  @impl Vigil.Plugin
  defdelegate plugin_id(), to: NoOp
  @impl Vigil.Plugin
  defdelegate display_name(), to: NoOp
  @impl Vigil.Plugin
  defdelegate contract_version(), to: NoOp
  @impl Vigil.Plugin
  defdelegate config_schema(), to: NoOp
  @impl Vigil.Plugin
  defdelegate defaults(), to: NoOp
  @impl Vigil.Plugin
  defdelegate operational_permissions(), to: NoOp
  @impl Vigil.Plugin
  defdelegate child_spec(arg), to: NoOp

  @impl Vigil.Plugin.Health
  defdelegate health_check(integration_id), to: NoOp

  @impl Vigil.Plugin.Inventory
  defdelegate list_nodes(integration_id, opts), to: NoOp

  @impl Vigil.Plugin.Execution.Runner
  defdelegate start(integration_id, artifact, targets, opts), to: NoOp
  @impl Vigil.Plugin.Execution.Runner
  defdelegate abort(runner_ref), to: NoOp
end

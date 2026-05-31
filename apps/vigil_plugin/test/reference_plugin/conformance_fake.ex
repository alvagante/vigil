defmodule Vigil.Plugin.ConformanceFake do
  @moduledoc """
  Test-support plugin that conforms to the full contract (by delegating to
  `Vigil.Plugin.NoOp`). It implements the `:facts` capability so the suite's
  `FactsContract` has a known-good target to run against, and additionally
  declares a `:monitoring` capability for which no conformance contract exists
  yet — proving the suite flags uncontracted capabilities as warnings rather
  than passing silently (ROAD-105).
  """

  @behaviour Vigil.Plugin
  @behaviour Vigil.Plugin.Health
  @behaviour Vigil.Plugin.Inventory
  @behaviour Vigil.Plugin.Facts
  @behaviour Vigil.Plugin.Execution.Runner

  alias Vigil.Plugin.NoOp

  @impl Vigil.Plugin
  def capabilities, do: [:inventory, :execution, :facts, :monitoring]

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

  @impl Vigil.Plugin.Facts
  defdelegate get_facts(integration_id, args), to: NoOp

  @impl Vigil.Plugin.Execution.Runner
  defdelegate start(integration_id, artifact, targets, opts), to: NoOp
  @impl Vigil.Plugin.Execution.Runner
  defdelegate abort(runner_ref), to: NoOp
end

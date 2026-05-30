defmodule Vigil.Plugin.Conformance do
  @moduledoc """
  Runs the plugin contract conformance suite against a plugin module
  (design §3.7, PLUG-701..704).

  `run/2` starts the plugin's subtree with a test config, runs the lifecycle
  contract plus a contract for each declared capability, tears the subtree down,
  and returns a `Vigil.Plugin.Conformance.Report`. It never calls test
  assertions — the same report drives the test suite, startup Validation mode,
  and sibling plugin apps' own suites.

  ROAD-105 ("the suite grows with the contract"): each capability is mapped to
  its contract in `@capability_contracts`. A declared capability with no mapped
  contract yields a *warning*, never a silent pass — so adding a capability to
  the contract surfaces the missing conformance contract immediately.
  """

  alias Vigil.Plugin.Conformance.{Check, ExecutionContract, InventoryContract, LifecycleContract, Report}

  @capability_contracts %{
    inventory: InventoryContract,
    execution: ExecutionContract
  }

  @spec run(module(), Vigil.Plugin.config()) :: Report.t()
  def run(plugin, test_config \\ %{}) do
    integration_id = "conformance-" <> (System.unique_integer([:positive]) |> Integer.to_string())

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Vigil.Integrations.Supervisor,
        plugin.child_spec({integration_id, test_config})
      )

    context = %{plugin: plugin, integration_id: integration_id, config: test_config}

    try do
      checks = LifecycleContract.run(context) ++ capability_checks(context)
      Report.from_checks(plugin, checks)
    after
      DynamicSupervisor.terminate_child(Vigil.Integrations.Supervisor, pid)
    end
  end

  defp capability_checks(%{plugin: plugin} = context) do
    Enum.flat_map(plugin.capabilities(), fn capability ->
      case Map.fetch(@capability_contracts, capability) do
        {:ok, contract} ->
          contract.run(context)

        :error ->
          [
            Check.warn(
              "capability:#{capability}:no_contract",
              "capability #{inspect(capability)} is declared but has no conformance contract yet"
            )
          ]
      end
    end)
  end
end

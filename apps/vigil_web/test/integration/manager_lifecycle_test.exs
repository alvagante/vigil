defmodule Vigil.Integrations.ManagerLifecycleTest do
  @moduledoc """
  End-to-end lifecycle tests for `Vigil.Integrations.Manager`:
  enable → dispatch → disable (AC #2 and #3 from issue #5).

  These tests allow the persistent Manager GenServer into the Ecto sandbox so it
  can read DB rows that were created in the test's sandbox transaction.
  """

  use VigilWeb.DataCase, async: false

  alias Vigil.Core.IntegrationConfig
  alias Vigil.Plugin.{Catalog, Dispatcher}

  setup do
    # Allow the persistent Manager to access this test's sandbox connection.
    Ecto.Adapters.SQL.Sandbox.allow(
      Vigil.Repo,
      self(),
      Process.whereis(Vigil.Integrations.Manager)
    )

    # Ensure the no-op plugin is discoverable.
    Catalog.register("noop", Vigil.Plugin.NoOp)

    :ok
  end

  test "enable spawns the integration subtree and makes it dispatchable (AC #2)" do
    {:ok, integration} =
      IntegrationConfig.create(%{
        plugin_id: "noop",
        name: "lifecycle-enable",
        contract_version: "1.0.0",
        enabled: false
      })

    id = integration.id

    # Before enabling: not dispatchable
    assert {:error, _} = Dispatcher.call(id, :inventory, :list_nodes, %{})

    {:ok, _} = IntegrationConfig.enable(id)

    # After enabling: Manager reacts to PubSub, spawns subtree; poll until ready
    assert eventually(fn ->
             match?({:ok, _}, Dispatcher.call(id, :inventory, :list_nodes, %{}))
           end),
           "integration #{id} never became dispatchable after enable"
  end

  test "disable terminates the integration subtree (AC #3)" do
    {:ok, integration} =
      IntegrationConfig.create(%{
        plugin_id: "noop",
        name: "lifecycle-disable",
        contract_version: "1.0.0",
        enabled: false
      })

    id = integration.id

    {:ok, _} = IntegrationConfig.enable(id)

    # Wait for enable to take effect
    assert eventually(fn ->
             match?({:ok, _}, Dispatcher.call(id, :inventory, :list_nodes, %{}))
           end),
           "integration #{id} never started after enable"

    {:ok, _} = IntegrationConfig.disable(id)

    # After disabling: Manager terminates the subtree; poll until un-dispatchable
    assert eventually(fn ->
             match?({:error, _}, Dispatcher.call(id, :inventory, :list_nodes, %{}))
           end),
           "integration #{id} still dispatchable after disable"
  end

  # Poll `fun` up to ~500ms with 10ms steps. Returns true if `fun` becomes true.
  defp eventually(fun, attempts \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end
end

defmodule Vigil.Plugin.DispatcherTest do
  use ExUnit.Case, async: false

  alias Vigil.Plugin.{Dispatcher, Error, Result}

  setup do
    integration_id = "noop-" <> (System.unique_integer([:positive]) |> Integer.to_string())
    {:ok, _} = Registry.register(Vigil.Plugin.Registry, {:integration, integration_id}, Vigil.Plugin.NoOp)
    %{integration_id: integration_id}
  end

  test "resolves the registered plugin and returns a typed Result", %{integration_id: id} do
    assert {:ok, %Result{} = result} = Dispatcher.call(id, :inventory, :list_nodes, %{})
    assert result.data == []
    assert result.source.integration_id == id
    assert result.source.plugin_id == "noop"
  end

  test "returns a structured configuration error when the integration is unknown" do
    assert {:error, %Error{category: :configuration} = error} =
             Dispatcher.call("does-not-exist", :inventory, :list_nodes, %{})

    assert error.retriable? == false
    assert error.message =~ "does-not-exist"
  end

  test "a plugin started through its child_spec under Integrations.Supervisor is dispatchable" do
    integration_id = "noop-lifecycle-" <> (System.unique_integer([:positive]) |> Integer.to_string())

    spec = Vigil.Plugin.NoOp.child_spec({integration_id, %{}})
    {:ok, pid} = DynamicSupervisor.start_child(Vigil.Integrations.Supervisor, spec)
    on_exit(fn -> if Process.alive?(pid), do: DynamicSupervisor.terminate_child(Vigil.Integrations.Supervisor, pid) end)

    assert {:ok, %Result{} = result} = Dispatcher.call(integration_id, :inventory, :list_nodes, %{})
    assert result.source.integration_id == integration_id
  end

  test "an integration is no longer dispatchable after its subtree is shut down" do
    integration_id = "noop-shutdown-" <> (System.unique_integer([:positive]) |> Integer.to_string())

    spec = Vigil.Plugin.NoOp.child_spec({integration_id, %{}})
    {:ok, pid} = DynamicSupervisor.start_child(Vigil.Integrations.Supervisor, spec)
    assert {:ok, %Result{}} = Dispatcher.call(integration_id, :inventory, :list_nodes, %{})

    :ok = DynamicSupervisor.terminate_child(Vigil.Integrations.Supervisor, pid)

    # The Registry deregisters on the process :DOWN, which it handles
    # asynchronously — so the entry may briefly outlive terminate_child/2. Poll
    # until resolution fails rather than asserting instantaneous deregistration.
    assert eventually(fn ->
             match?(
               {:error, %Error{category: :configuration}},
               Dispatcher.call(integration_id, :inventory, :list_nodes, %{})
             )
           end)
  end

  defp eventually(fun, retries \\ 50) do
    Enum.reduce_while(1..retries, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(2)
        {:cont, false}
      end
    end)
  end
end

defmodule Vigil.Plugin.DispatcherTest do
  use ExUnit.Case, async: false

  alias Vigil.Plugin.{Dispatcher, Error, Result}

  setup do
    integration_id = "noop-" <> (System.unique_integer([:positive]) |> Integer.to_string())

    {:ok, _} =
      Registry.register(Vigil.Plugin.Registry, {:integration, integration_id}, Vigil.Plugin.NoOp)

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
    integration_id =
      "noop-lifecycle-" <> (System.unique_integer([:positive]) |> Integer.to_string())

    spec = Vigil.Plugin.NoOp.child_spec({integration_id, %{}})
    {:ok, pid} = DynamicSupervisor.start_child(Vigil.Integrations.Supervisor, spec)

    on_exit(fn ->
      if Process.alive?(pid),
        do: DynamicSupervisor.terminate_child(Vigil.Integrations.Supervisor, pid)
    end)

    assert {:ok, %Result{} = result} =
             Dispatcher.call(integration_id, :inventory, :list_nodes, %{})

    assert result.source.integration_id == integration_id
  end

  test "an integration is no longer dispatchable after its subtree is shut down" do
    integration_id =
      "noop-shutdown-" <> (System.unique_integer([:positive]) |> Integer.to_string())

    spec = Vigil.Plugin.NoOp.child_spec({integration_id, %{}})
    {:ok, pid} = DynamicSupervisor.start_child(Vigil.Integrations.Supervisor, spec)
    assert {:ok, %Result{}} = Dispatcher.call(integration_id, :inventory, :list_nodes, %{})

    :ok = DynamicSupervisor.terminate_child(Vigil.Integrations.Supervisor, pid)
    # Evict the cached result so the registry-miss is observable.
    Vigil.Core.Cache.invalidate(integration_id, :inventory)

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

  describe "EXS-006 — stale serving when source is unhealthy" do
    test "returns stale result with :stale freshness when upstream fails and expired entry exists" do
      id = "stale-" <> (System.unique_integer([:positive]) |> Integer.to_string())

      stale_result = %Result{
        data: [%{name: "stale-node"}],
        source: %Vigil.Plugin.Source{plugin_id: "noop", integration_id: id},
        fetched_at: DateTime.utc_now(),
        freshness: :live
      }

      Vigil.Core.Cache.put(
        id,
        :inventory,
        :list_nodes,
        %{},
        stale_result,
        %{plugin_id: "noop"},
        1
      )

      :timer.sleep(10)

      # No plugin registered → upstream fails → stale entry served
      assert {:ok, %Result{freshness: :stale, data: data}} =
               Dispatcher.call(id, :inventory, :list_nodes, %{})

      assert data == [%{name: "stale-node"}]
    end

    test "returns error when upstream fails and no stale entry exists" do
      assert {:error, %Error{category: :configuration}} =
               Dispatcher.call("no-such-integration", :inventory, :list_nodes, %{})
    end
  end

  describe "cache wiring" do
    test "cache hit returns cached data without calling the plugin", %{integration_id: id} do
      # Prime the cache with a known result.
      cached_nodes = [%{name: "cached-node", attributes: %{}, targetable?: true}]

      cached_result = %Result{
        data: cached_nodes,
        source: %Vigil.Plugin.Source{plugin_id: "noop", integration_id: id},
        fetched_at: ~U[2000-01-01 00:00:00Z],
        freshness: :cached
      }

      Vigil.Core.Cache.put(id, :inventory, :list_nodes, %{}, cached_result, %{}, 300_000)

      assert {:ok, %Result{data: ^cached_nodes, freshness: :cached}} =
               Dispatcher.call(id, :inventory, :list_nodes, %{})
    end

    test "cache miss calls plugin, result is served with :live freshness then :cached", %{
      integration_id: id
    } do
      # First call — cache miss — hits the NoOp plugin.
      assert {:ok, %Result{freshness: :live} = result} =
               Dispatcher.call(id, :inventory, :list_nodes, %{})

      assert result.source.integration_id == id

      # Second call — cache hit — returns the stored entry with :cached freshness.
      assert {:ok, %Result{freshness: :cached}} =
               Dispatcher.call(id, :inventory, :list_nodes, %{})
    end

    test "error from plugin is not cached — retry hits the plugin again" do
      # Unknown integration → error; should not pollute cache.
      assert {:error, %Error{}} =
               Dispatcher.call("unknown-for-cache-test", :inventory, :list_nodes, %{})

      assert {:error, %Error{}} =
               Dispatcher.call("unknown-for-cache-test", :inventory, :list_nodes, %{})
    end
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

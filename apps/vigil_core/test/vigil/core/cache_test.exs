defmodule Vigil.Core.CacheTest do
  use ExUnit.Case, async: false

  alias Vigil.Core.Cache

  setup_all do
    case Process.whereis(Vigil.Core.Cache.Server) do
      nil -> start_supervised!(Vigil.Core.Cache.Server)
      _pid -> :ok
    end

    :ok
  end

  # Use unique integration IDs per test to avoid cross-test ETS pollution.
  defp uid, do: "integ-#{:erlang.unique_integer([:positive])}"

  describe "get/4 and put/7" do
    test "returns :miss when no entry exists" do
      assert :miss = Cache.get(uid(), :inventory, :list_nodes, %{})
    end

    test "returns {:ok, entry} after put — entry carries stored data and attribution" do
      id = uid()
      data = [%{name: "node1"}]
      source = %{plugin_id: "puppet"}

      :ok = Cache.put(id, :inventory, :list_nodes, %{}, data, source, 60_000)

      assert {:ok, entry} = Cache.get(id, :inventory, :list_nodes, %{})
      assert entry.data == data
      assert entry.source_attribution == source
      assert %DateTime{} = entry.stored_at
      assert %DateTime{} = entry.expires_at
    end

    test "args map is identity-matched — different args miss" do
      id = uid()
      Cache.put(id, :inventory, :list_nodes, %{"env" => "prod"}, [:node_a], %{}, 60_000)

      assert :miss = Cache.get(id, :inventory, :list_nodes, %{})
      assert :miss = Cache.get(id, :inventory, :list_nodes, %{"env" => "staging"})
      assert {:ok, _} = Cache.get(id, :inventory, :list_nodes, %{"env" => "prod"})
    end

    test "returns :miss for expired entries" do
      id = uid()
      Cache.put(id, :inventory, :list_nodes, %{}, [:stale], %{}, 1)
      :timer.sleep(20)

      assert :miss = Cache.get(id, :inventory, :list_nodes, %{})
    end

    test "overwrites stale entry with fresh put" do
      id = uid()
      Cache.put(id, :inventory, :list_nodes, %{}, [:old], %{}, 1)
      :timer.sleep(20)
      Cache.put(id, :inventory, :list_nodes, %{}, [:new], %{}, 60_000)

      assert {:ok, entry} = Cache.get(id, :inventory, :list_nodes, %{})
      assert entry.data == [:new]
    end
  end

  describe "fetch/6 — check-or-compute with single-flight coalescing" do
    test "cache hit returns cached data without calling compute_fn, tagged :hit" do
      id = uid()
      data = [%{name: "cached_node"}]
      Cache.put(id, :inventory, :list_nodes, %{}, data, %{}, 60_000)

      called = :counters.new(1, [])

      result =
        Cache.fetch(id, :inventory, :list_nodes, %{}, 60_000, fn ->
          :counters.add(called, 1, 1)
          {:ok, [:should_not_reach]}
        end)

      assert {:ok, entry, :hit} = result
      assert entry.data == data
      assert :counters.get(called, 1) == 0
    end

    test "cache miss calls compute_fn and caches the result, tagged :miss" do
      id = uid()

      assert {:ok, entry, :miss} =
               Cache.fetch(id, :inventory, :list_nodes, %{}, 60_000, fn ->
                 {:ok, [:computed_node]}
               end)

      assert entry.data == [:computed_node]
      # Subsequent get hits the cache — also tagged :hit
      assert {:ok, hit, :hit} = Cache.fetch(id, :inventory, :list_nodes, %{}, 60_000, fn -> {:ok, :noop} end)
      assert hit.data == [:computed_node]
    end

    test "compute_fn error is propagated and not cached" do
      id = uid()

      assert {:error, :upstream_down} =
               Cache.fetch(id, :inventory, :list_nodes, %{}, 60_000, fn ->
                 {:error, :upstream_down}
               end)

      assert :miss = Cache.get(id, :inventory, :list_nodes, %{})
    end

    test "concurrent misses coalesce — compute_fn is called exactly once (TEST-204)" do
      id = uid()
      called = :counters.new(1, [])
      test_pid = self()

      # Launch 5 concurrent callers with the same key
      tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            Cache.fetch(id, :inventory, :list_nodes, %{}, 60_000, fn ->
              :counters.add(called, 1, 1)
              # Small delay so all callers pile up before the compute completes
              Process.sleep(50)
              send(test_pid, {:computed, self()})
              {:ok, [:coalesced_result]}
            end)
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # Every caller gets the result — :miss for the leader, :miss for all waiters
      # (all were waiting on the same in-flight computation)
      assert Enum.all?(results, fn {:ok, e, _tag} -> e.data == [:coalesced_result] end)
      # Compute ran exactly once
      assert :counters.get(called, 1) == 1
    end
  end

  describe "invalidate/2" do
    test "removes all entries for the given {integration_id, capability}" do
      id = uid()
      Cache.put(id, :inventory, :list_nodes, %{}, [:a], %{}, 60_000)
      Cache.put(id, :inventory, :list_nodes, %{"env" => "prod"}, [:b], %{}, 60_000)

      :ok = Cache.invalidate(id, :inventory)

      assert :miss = Cache.get(id, :inventory, :list_nodes, %{})
      assert :miss = Cache.get(id, :inventory, :list_nodes, %{"env" => "prod"})
    end

    test "does not affect entries for other integrations" do
      id_a = uid()
      id_b = uid()
      Cache.put(id_a, :inventory, :list_nodes, %{}, [:a], %{}, 60_000)
      Cache.put(id_b, :inventory, :list_nodes, %{}, [:b], %{}, 60_000)

      Cache.invalidate(id_a, :inventory)

      assert :miss = Cache.get(id_a, :inventory, :list_nodes, %{})
      assert {:ok, _} = Cache.get(id_b, :inventory, :list_nodes, %{})
    end

    test "does not affect entries for other capabilities on the same integration" do
      id = uid()
      Cache.put(id, :inventory, :list_nodes, %{}, [:inv], %{}, 60_000)
      Cache.put(id, :facts, :get_facts, %{}, [:facts], %{}, 60_000)

      Cache.invalidate(id, :inventory)

      assert :miss = Cache.get(id, :inventory, :list_nodes, %{})
      assert {:ok, _} = Cache.get(id, :facts, :get_facts, %{})
    end
  end
end

defmodule Vigil.Core.CacheTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Vigil.Core.Cache
  alias Vigil.Core.Cache.Janitor

  setup_all do
    case Process.whereis(Vigil.Core.Cache.Server) do
      nil -> start_supervised!(Vigil.Core.Cache.Server)
      _pid -> :ok
    end

    case Process.whereis(Janitor) do
      nil -> start_supervised!(Janitor)
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
      assert {:ok, hit, :hit} =
               Cache.fetch(id, :inventory, :list_nodes, %{}, 60_000, fn -> {:ok, :noop} end)

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

  describe "TEST-204 — cache keys are fully determined by {integration_id, capability, action, args}" do
    property "any two calls with the same coordinates share the cached result" do
      check all(
              int_id <- string(:alphanumeric, min_length: 1),
              cap <- member_of([:inventory, :facts, :reports]),
              action <- member_of([:list_nodes, :get_facts]),
              args <-
                map_of(string(:alphanumeric, min_length: 1), string(:alphanumeric, min_length: 1),
                  max_length: 3
                )
            ) do
        # Unique integration_id per iteration to avoid cross-iteration pollution
        unique_id = "prop-#{int_id}-#{:erlang.unique_integer([:positive])}"
        data = [%{node: unique_id}]

        :ok = Cache.put(unique_id, cap, action, args, data, %{}, 60_000)

        # Same coordinates → always a hit, regardless of any external "principal" data
        assert {:ok, entry} = Cache.get(unique_id, cap, action, args)
        assert entry.data == data
      end
    end

    property "varying any key dimension yields a miss" do
      check all(
              int_id <- string(:alphanumeric, min_length: 3),
              cap <- member_of([:inventory, :facts]),
              action <- member_of([:list_nodes, :get_facts]),
              args <-
                map_of(string(:alphanumeric, min_length: 1), string(:alphanumeric, min_length: 1),
                  max_length: 2
                )
            ) do
        unique_id = "prop-dim-#{int_id}-#{:erlang.unique_integer([:positive])}"
        :ok = Cache.put(unique_id, cap, action, args, [:data], %{}, 60_000)

        # Different integration → miss
        assert :miss = Cache.get("other-#{unique_id}", cap, action, args)
        # Different capability → miss
        other_cap = if cap == :inventory, do: :facts, else: :inventory
        assert :miss = Cache.get(unique_id, other_cap, action, args)
        # Different args → miss
        assert :miss = Cache.get(unique_id, cap, action, Map.put(args, "__sentinel__", "1"))
      end
    end
  end

  describe "EXS-006 — stale serving when source is unhealthy" do
    test "fetch returns stale entry with :degraded marker when compute_fn fails and expired entry exists" do
      id = uid()
      # Populate cache with a fresh entry
      Cache.put(id, :inventory, :list_nodes, %{}, [:good_data], %{plugin_id: "puppet"}, 1)
      # Wait for TTL to expire (entry is now stale but still in ETS)
      :timer.sleep(10)
      assert :miss = Cache.get(id, :inventory, :list_nodes, %{})

      # Source is unhealthy — compute_fn returns error
      result =
        Cache.fetch(id, :inventory, :list_nodes, %{}, 60_000, fn -> {:error, :upstream_down} end)

      assert {:ok, entry, :stale} = result
      assert entry.data == [:good_data]
      assert entry.source_health_at_store == :degraded
    end

    test "fetch returns error when compute_fn fails and no stale entry exists" do
      id = uid()

      result =
        Cache.fetch(id, :inventory, :list_nodes, %{}, 60_000, fn -> {:error, :upstream_down} end)

      assert {:error, :upstream_down} = result
    end

    test "fetch returns fresh data when compute_fn succeeds, ignoring any stale entry" do
      id = uid()
      Cache.put(id, :inventory, :list_nodes, %{}, [:old_data], %{}, 1)
      :timer.sleep(10)

      result =
        Cache.fetch(id, :inventory, :list_nodes, %{}, 60_000, fn -> {:ok, [:fresh_data]} end)

      assert {:ok, entry, :miss} = result
      assert entry.data == [:fresh_data]
      assert entry.source_health_at_store == :healthy
    end
  end

  describe "Janitor — TTL sweeper" do
    test "deletes entries past hard retention window" do
      id = uid()
      # TTL = 1 ms; wait for expiry; hard_retention = 5 ms → sweep should evict
      Cache.put(id, :inventory, :list_nodes, %{}, [:stale_data], %{}, 1)
      :timer.sleep(10)
      # Confirm TTL-expired (stale but still in ETS)
      assert :miss = Cache.get(id, :inventory, :list_nodes, %{})

      Janitor.sweep(5)

      # After sweep: entry should be gone from ETS
      refute match?(
               [_],
               :ets.lookup(:vigil_cache, {id, :inventory, :list_nodes, :erlang.phash2(%{})})
             )
    end

    test "does not delete entries within hard retention window" do
      id = uid()
      # TTL = 1 ms (expired); hard retention = 10 minutes → NOT deleted by sweep
      Cache.put(id, :inventory, :list_nodes, %{}, [:stale_data], %{}, 1)
      :timer.sleep(10)

      Janitor.sweep(600_000)

      # Entry must still be present (stale but available for EXS-006)
      assert match?(
               [_],
               :ets.lookup(:vigil_cache, {id, :inventory, :list_nodes, :erlang.phash2(%{})})
             )
    end

    test "does not delete live entries" do
      id = uid()
      Cache.put(id, :inventory, :list_nodes, %{}, [:live_data], %{}, 60_000)

      Janitor.sweep(5)

      assert {:ok, _} = Cache.get(id, :inventory, :list_nodes, %{})
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

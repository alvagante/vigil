defmodule Vigil.Plugin.Workers.CacheWarmerTest do
  use ExUnit.Case, async: false

  alias Vigil.Core.Cache
  alias Vigil.Plugin.Workers.CacheWarmer

  # Unique integration_id per test to avoid ETS cross-pollution.
  defp uid, do: "warm-#{:erlang.unique_integer([:positive])}"

  setup do
    id = uid()

    {:ok, _} =
      Registry.register(Vigil.Plugin.Registry, {:integration, id}, Vigil.Plugin.NoOp)

    %{integration_id: id}
  end

  test "perform/1 warms the inventory cache for the given integration", %{integration_id: id} do
    # Cache is cold before the worker runs.
    assert :miss = Cache.get(id, :inventory, :list_nodes, %{})

    job = %Oban.Job{args: %{"integration_id" => id, "capability" => "inventory"}}
    assert :ok = CacheWarmer.perform(job)

    # Cache is populated after the worker runs.
    assert {:ok, entry} = Cache.get(id, :inventory, :list_nodes, %{})
    assert entry.source_attribution != nil
  end

  test "perform/1 returns error for an unregistered integration" do
    job = %Oban.Job{args: %{"integration_id" => "no-such-integration", "capability" => "inventory"}}

    assert {:error, _} = CacheWarmer.perform(job)
  end
end

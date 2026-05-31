defmodule Vigil.Plugin.Health.WorkerTest do
  use ExUnit.Case, async: false

  alias Vigil.Plugin.Health.Worker

  setup do
    integration_id = "health-test-#{System.unique_integer([:positive])}"
    %{integration_id: integration_id}
  end

  test "worker publishes health status to integration_health topic on start", %{integration_id: id} do
    Phoenix.PubSub.subscribe(Vigil.PubSub, "integration_health:#{id}")

    {:ok, pid} = Worker.start_link({id, Vigil.Plugin.NoOp, [interval_ms: 60_000]})
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)

    assert_receive {:health, ^id, :healthy, capabilities, _diagnostic}, 500
    assert :inventory in capabilities
  end

  test "worker publishes to integration_health:all", %{integration_id: id} do
    Phoenix.PubSub.subscribe(Vigil.PubSub, "integration_health:all")

    {:ok, pid} = Worker.start_link({id, Vigil.Plugin.NoOp, [interval_ms: 60_000]})
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)

    assert_receive {:health, _id, :healthy, _caps, _diag}, 500
  end

  test "worker registers itself in Vigil.Plugin.Registry under {:health_worker, id}", %{integration_id: id} do
    {:ok, pid} = Worker.start_link({id, Vigil.Plugin.NoOp, [interval_ms: 60_000]})
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)

    # Allow registration to complete
    Process.sleep(10)

    assert [{^pid, Vigil.Plugin.Health.Worker}] =
             Registry.lookup(Vigil.Plugin.Registry, {:health_worker, id})
  end

  test "worker sends repeated health checks at the configured interval", %{integration_id: id} do
    Phoenix.PubSub.subscribe(Vigil.PubSub, "integration_health:#{id}")

    {:ok, pid} = Worker.start_link({id, Vigil.Plugin.NoOp, [interval_ms: 50]})
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)

    # Should receive at least two health reports within 200ms
    assert_receive {:health, _, :healthy, _, _}, 200
    assert_receive {:health, _, :healthy, _, _}, 200
  end
end

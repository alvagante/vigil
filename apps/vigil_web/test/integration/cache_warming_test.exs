defmodule Vigil.Plugin.Cache.WarmerTest do
  @moduledoc """
  Integration test for `Vigil.Plugin.Cache.Warmer` (CACHE-009, design §5.10).

  Verifies that the Warmer GenServer enqueues CacheWarmer jobs when it receives
  a `:healthy` integration health event, simulating the post-boot warm pass.
  """

  use VigilWeb.DataCase, async: false
  use Oban.Testing, repo: Vigil.Repo

  alias Vigil.Core.IntegrationConfig
  alias Vigil.Plugin.{Cache.Warmer, Catalog}

  setup do
    Catalog.register("noop", Vigil.Plugin.NoOp)
    :ok
  end

  test "health :healthy event enqueues a CacheWarmer job for the integration" do
    {:ok, integ} =
      IntegrationConfig.create(%{
        plugin_id: "noop",
        name: "warm-noop-#{System.unique_integer([:positive])}",
        contract_version: "1.0.0",
        enabled: true
      })

    # Start the Warmer under test (isolated; not the global application instance).
    # boot_delay_ms: 0 fires :first_warm_pass immediately so the test doesn't wait 10 s.
    {:ok, pid} = start_supervised({Warmer, [boot_delay_ms: 0]})

    # Allow the Warmer to query the DB inside this sandbox.
    Ecto.Adapters.SQL.Sandbox.allow(Vigil.Repo, self(), pid)

    # Simulate a health :healthy event arriving (as Health.Worker broadcasts).
    send(pid, {:health, integ.id, :healthy, [:inventory], %{}})

    # Give the GenServer time to process the message and insert the Oban job.
    Process.sleep(50)

    enqueued = all_enqueued(worker: Vigil.Plugin.Workers.CacheWarmer)

    assert Enum.any?(enqueued, fn job ->
             job.args["integration_id"] == integ.id and
               job.args["capability"] == "inventory"
           end),
           "Expected a CacheWarmer job for #{integ.id}:inventory; got #{inspect(Enum.map(enqueued, & &1.args))}"
  end

  test "same integration is not warmed twice within one Warmer lifecycle" do
    {:ok, integ} =
      IntegrationConfig.create(%{
        plugin_id: "noop",
        name: "warm-dedup-#{System.unique_integer([:positive])}",
        contract_version: "1.0.0",
        enabled: true
      })

    {:ok, pid} = start_supervised({Warmer, [boot_delay_ms: 60_000]})
    Ecto.Adapters.SQL.Sandbox.allow(Vigil.Repo, self(), pid)

    # Send two health :healthy events for the same integration.
    send(pid, {:health, integ.id, :healthy, [:inventory], %{}})
    send(pid, {:health, integ.id, :healthy, [:inventory], %{}})

    Process.sleep(100)

    enqueued =
      all_enqueued(worker: Vigil.Plugin.Workers.CacheWarmer)
      |> Enum.filter(fn j -> j.args["integration_id"] == integ.id end)

    assert length(enqueued) == 1,
           "Expected 1 job for #{integ.id}; got #{length(enqueued)} — Warmer is enqueuing duplicates"
  end
end

defmodule Vigil.Plugin.Cache.Warmer do
  @moduledoc """
  Warm the shared integration cache at boot for integrations with minutes-scale
  TTLs (design §5.10, CACHE-009).

  Subscribes to `"integration_health:all"` on startup. When a `:healthy` event
  arrives for an integration not yet warmed in this process lifetime, it enqueues
  one `CacheWarmer` Oban job per warmable capability into the `:maintenance` queue.

  A `:first_warm_pass` message (sent after boot delay) also triggers warming for
  all currently-healthy integrations.

  Deferrals: `warm_on_boot` per-integration config field (no migration), telemetry
  source-tagging, coalescer-skip. Only `:inventory` is warmed (facts warm lazily).
  """

  use GenServer, restart: :permanent

  require Logger

  alias Vigil.Core.IntegrationConfig
  alias Vigil.Plugin.{Catalog, Workers.CacheWarmer}

  @pubsub Vigil.PubSub
  @warmable_capabilities [:inventory]
  @default_boot_delay_ms 10_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    delay = Keyword.get(opts, :boot_delay_ms, @default_boot_delay_ms)
    Phoenix.PubSub.subscribe(@pubsub, "integration_health:all")
    Process.send_after(self(), :first_warm_pass, delay)
    {:ok, %{warmed: MapSet.new()}}
  end

  @impl GenServer
  def handle_info(:first_warm_pass, state) do
    new_warmed =
      IntegrationConfig.list_enabled()
      |> Enum.reduce(state.warmed, fn integ, acc ->
        if MapSet.member?(acc, integ.id) do
          acc
        else
          enqueue_warm_jobs(integ.id, integ.plugin_id)
          MapSet.put(acc, integ.id)
        end
      end)

    {:noreply, %{state | warmed: new_warmed}}
  end

  def handle_info({:health, int_id, :healthy, _caps, _diag}, state) do
    if MapSet.member?(state.warmed, int_id) do
      {:noreply, state}
    else
      plugin_id = lookup_plugin_id(int_id)
      enqueue_warm_jobs(int_id, plugin_id)
      {:noreply, %{state | warmed: MapSet.put(state.warmed, int_id)}}
    end
  end

  def handle_info({:health, _int_id, _status, _caps, _diag}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp enqueue_warm_jobs(int_id, plugin_id) do
    case Catalog.lookup(plugin_id) do
      {:ok, module} ->
        caps = module.capabilities()

        for cap <- @warmable_capabilities, cap in caps do
          %{"integration_id" => int_id, "capability" => Atom.to_string(cap)}
          |> CacheWarmer.new()
          |> Oban.insert()
        end

      {:error, :not_found} ->
        Logger.debug("[cache:warmer] plugin not found for integration #{int_id}, skipping warm")
    end
  end

  defp lookup_plugin_id(int_id) do
    try do
      IntegrationConfig.get!(int_id).plugin_id
    rescue
      _ -> nil
    end
  end
end

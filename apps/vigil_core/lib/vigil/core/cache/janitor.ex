defmodule Vigil.Core.Cache.Janitor do
  @moduledoc false

  use GenServer

  @default_sweep_interval_ms 60_000
  # How long past expires_at before an entry is evicted (for EXS-006 stale serving).
  @default_hard_retention_ms 600_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    sweep_interval = Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms)
    hard_retention = Keyword.get(opts, :hard_retention_ms, @default_hard_retention_ms)

    schedule_sweep(sweep_interval)

    {:ok, %{sweep_interval_ms: sweep_interval, hard_retention_ms: hard_retention}}
  end

  @doc "Trigger an immediate sweep with the given hard-retention window. Synchronous."
  def sweep(hard_retention_ms) do
    Vigil.Core.Cache.Server.sweep(hard_retention_ms)
  end

  @impl true
  def handle_info(:sweep, state) do
    Vigil.Core.Cache.Server.sweep(state.hard_retention_ms)
    schedule_sweep(state.sweep_interval_ms)
    {:noreply, state}
  end

  defp schedule_sweep(interval_ms) do
    Process.send_after(self(), :sweep, interval_ms)
  end
end

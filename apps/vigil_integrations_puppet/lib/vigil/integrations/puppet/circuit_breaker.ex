defmodule Vigil.Integrations.Puppet.CircuitBreaker do
  @moduledoc """
  Per-integration circuit breaker implementing RES-002:
  - Opens after `threshold` consecutive failures (default 5, configurable via `circuit_breaker.threshold`).
  - Stays open for `cooldown_ms` (default 30s, configurable via `circuit_breaker.cooldown_ms`).
  - After cooldown, allows a single probe call; success closes, failure re-opens.

  State machine: :closed → :open (on threshold) → :half_open (after cooldown) → :closed/:open
  """

  use GenServer

  @registry Vigil.Plugin.Registry

  defstruct state: :closed,
            failures: 0,
            opened_at: nil,
            threshold: 5,
            cooldown_ms: 30_000

  def start_link({integration_id, config}) do
    GenServer.start_link(__MODULE__, {integration_id, config},
      name: via(integration_id)
    )
  end

  @doc "Returns :ok when calls may proceed, or {:error, :open} when the breaker is tripped."
  @spec check(Vigil.Plugin.integration_id()) :: :ok | {:error, :open}
  def check(integration_id) do
    GenServer.call(via(integration_id), :check)
  end

  @doc "Records a transient failure. Opens the breaker at threshold."
  @spec record_failure(Vigil.Plugin.integration_id()) :: :ok
  def record_failure(integration_id) do
    GenServer.cast(via(integration_id), :failure)
  end

  @doc "Records a success. Closes the breaker if half-open; resets failure counter."
  @spec record_success(Vigil.Plugin.integration_id()) :: :ok
  def record_success(integration_id) do
    GenServer.cast(via(integration_id), :success)
  end

  @doc "Forces transition to :half_open for testing cooldown bypass."
  @spec force_probe(Vigil.Plugin.integration_id()) :: :ok
  def force_probe(integration_id) do
    GenServer.call(via(integration_id), :force_probe)
  end

  @impl GenServer
  def init({_integration_id, config}) do
    threshold = Map.get(config, "circuit_breaker.threshold", 5)
    cooldown_ms = Map.get(config, "circuit_breaker.cooldown_ms", 30_000)
    {:ok, %__MODULE__{threshold: threshold, cooldown_ms: cooldown_ms}}
  end

  @impl GenServer
  def handle_call(:check, _from, %{state: :closed} = s) do
    {:reply, :ok, s}
  end

  def handle_call(:check, _from, %{state: :open, opened_at: opened_at} = s) do
    elapsed = System.monotonic_time(:millisecond) - opened_at

    if elapsed >= s.cooldown_ms do
      {:reply, :ok, %{s | state: :half_open}}
    else
      {:reply, {:error, :open}, s}
    end
  end

  def handle_call(:check, _from, %{state: :half_open} = s) do
    {:reply, :ok, s}
  end

  def handle_call(:force_probe, _from, s) do
    {:reply, :ok, %{s | state: :half_open}}
  end

  @impl GenServer
  def handle_cast(:failure, %{state: :closed, failures: f} = s) do
    new_failures = f + 1

    if new_failures >= s.threshold do
      {:noreply, %{s | state: :open, failures: new_failures, opened_at: now()}}
    else
      {:noreply, %{s | failures: new_failures}}
    end
  end

  def handle_cast(:failure, %{state: :half_open} = s) do
    {:noreply, %{s | state: :open, opened_at: now()}}
  end

  def handle_cast(:failure, %{state: :open} = s), do: {:noreply, s}

  def handle_cast(:success, %{state: :half_open} = s) do
    {:noreply, %{s | state: :closed, failures: 0, opened_at: nil}}
  end

  def handle_cast(:success, %{state: :closed} = s) do
    {:noreply, %{s | failures: 0}}
  end

  def handle_cast(:success, s), do: {:noreply, s}

  defp via(id), do: {:via, Registry, {@registry, {:circuit_breaker, id}}}
  defp now, do: System.monotonic_time(:millisecond)
end

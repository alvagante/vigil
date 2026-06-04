defmodule Vigil.Core.Cache.Server do
  @moduledoc false

  use GenServer

  alias Vigil.Core.Cache.Entry

  @table :vigil_cache

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, {:read_concurrency, true}])
    # in_flight: %{cache_key => [waiting_from]}
    {:ok, %{in_flight: %{}}}
  end

  # --- Read API (bypasses GenServer — direct ETS) ---

  def get(integration_id, capability, action, args) do
    key = cache_key(integration_id, capability, action, args)

    case :ets.lookup(@table, key) do
      [{^key, entry}] ->
        if Entry.expired?(entry), do: :miss, else: {:ok, entry}

      [] ->
        :miss
    end
  end

  # Returns expired-but-present entries for EXS-006 stale serving.
  defp get_stale(integration_id, capability, action, args) do
    key = cache_key(integration_id, capability, action, args)

    case :ets.lookup(@table, key) do
      [{^key, entry}] -> {:ok, entry}
      [] -> :miss
    end
  end

  # --- Write API (goes through GenServer) ---

  def put(integration_id, capability, action, args, data, source_attribution, ttl_ms) do
    GenServer.call(
      __MODULE__,
      {:put, integration_id, capability, action, args, data, source_attribution, ttl_ms}
    )
  end

  def invalidate(integration_id, capability) do
    GenServer.call(__MODULE__, {:invalidate, integration_id, capability})
  end

  def invalidate_integration(integration_id) do
    GenServer.call(__MODULE__, {:invalidate_integration, integration_id})
  end

  @doc """
  Check-or-compute with single-flight coalescing (TEST-204, EXEC-005).
  If a live cache entry exists, returns it immediately (ETS direct read before
  the GenServer call). On miss, routes through GenServer to coalesce concurrent
  identical misses into one compute_fn invocation.
  """
  def fetch(integration_id, capability, action, args, ttl_ms, compute_fn) do
    # Fast path: hit the ETS table before entering the GenServer.
    case get(integration_id, capability, action, args) do
      {:ok, entry} ->
        {:ok, entry, :hit}

      :miss ->
        key = cache_key(integration_id, capability, action, args)

        GenServer.call(
          __MODULE__,
          {:fetch_or_compute, key, integration_id, capability, action, args, ttl_ms, compute_fn},
          30_000
        )
    end
  end

  @impl true
  def handle_call(
        {:put, integration_id, capability, action, args, data, source_attribution, ttl_ms},
        _from,
        state
      ) do
    key = cache_key(integration_id, capability, action, args)
    entry = Entry.new(data, source_attribution, ttl_ms)
    :ets.insert(@table, {key, entry})
    {:reply, :ok, state}
  end

  def handle_call({:invalidate, integration_id, capability}, _from, state) do
    :ets.match_delete(@table, {{integration_id, capability, :_, :_}, :_})
    {:reply, :ok, state}
  end

  def handle_call({:invalidate_integration, integration_id}, _from, state) do
    :ets.match_delete(@table, {{integration_id, :_, :_, :_}, :_})
    {:reply, :ok, state}
  end

  def handle_call({:sweep, hard_retention_ms}, _from, state) do
    cutoff = DateTime.add(DateTime.utc_now(), -hard_retention_ms, :millisecond)

    keys_to_delete =
      :ets.foldl(
        fn {key, entry}, acc ->
          if DateTime.compare(entry.expires_at, cutoff) == :lt, do: [key | acc], else: acc
        end,
        [],
        @table
      )

    Enum.each(keys_to_delete, &:ets.delete(@table, &1))
    {:reply, :ok, state}
  end

  def handle_call(
        {:fetch_or_compute, key, integration_id, capability, action, args, ttl_ms, compute_fn},
        from,
        state
      ) do
    # Re-check cache under GenServer lock — another caller may have populated it.
    case get(integration_id, capability, action, args) do
      {:ok, entry} ->
        {:reply, {:ok, entry, :hit}, state}

      :miss ->
        in_flight = state.in_flight

        if Map.has_key?(in_flight, key) do
          # Another caller is already computing — queue behind it.
          waiters = [from | Map.fetch!(in_flight, key)]
          {:noreply, %{state | in_flight: Map.put(in_flight, key, waiters)}}
        else
          # First caller for this key — become the leader.
          # Run compute_fn in a Task so the GenServer remains unblocked.
          server = self()

          Task.start(fn ->
            result = compute_fn.()

            GenServer.cast(
              server,
              {:compute_done, key, integration_id, capability, action, args, ttl_ms, result, from}
            )
          end)

          {:noreply, %{state | in_flight: Map.put(in_flight, key, [])}}
        end
    end
  end

  def sweep(hard_retention_ms) do
    GenServer.call(__MODULE__, {:sweep, hard_retention_ms})
  end

  @impl true
  def handle_cast(
        {:compute_done, key, integration_id, capability, action, args, ttl_ms, result,
         leader_from},
        state
      ) do
    {waiters, in_flight} = Map.pop(state.in_flight, key, [])

    tagged_reply =
      case result do
        {:ok, data} ->
          entry = Entry.new(data, %{}, ttl_ms)
          :ets.insert(@table, {key, entry})
          {:ok, entry, :miss}

        {:error, _} = err ->
          # EXS-006: serve stale entry with :degraded marker if available.
          case get_stale(integration_id, capability, action, args) do
            {:ok, stale_entry} ->
              {:ok, %{stale_entry | source_health_at_store: :degraded}, :stale}

            :miss ->
              err
          end
      end

    GenServer.reply(leader_from, tagged_reply)
    Enum.each(waiters, &GenServer.reply(&1, tagged_reply))

    {:noreply, %{state | in_flight: in_flight}}
  end

  defp cache_key(integration_id, capability, action, args) do
    {integration_id, capability, action, :erlang.phash2(args)}
  end
end

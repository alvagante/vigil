defmodule Vigil.Integrations.SSH.ConnectionPool do
  @moduledoc """
  Per-integration connection pool that amortizes SSH session-establishment cost
  across consecutive commands to the same host (`SSH-302`) and reconnects
  transparently when a cached connection has died (`SSH-405` resilience).

  One pool process per integration holds at most one live connection per host.
  `run/4` lazily connects, executes, and on a transport-level failure drops the
  dead connection and retries once with a fresh one — so a reconnect is
  invisible to the caller. Multi-connection-per-host pooling and concurrency
  limits are the execution slice's concern (#7); here a single connection per
  host is sufficient for inventory facts and health probes.

  Per-host connect options (port, user, identity file) are resolved lazily via
  the optional `:host_resolver` function so different hosts can carry different
  credentials.
  """

  use GenServer
  require Logger

  alias Vigil.Plugin.Error

  @default_timeout 10_000

  ## Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, gen_opts(opts))
  end

  @doc """
  Run `command` on `host`, returning the transport's exec result or a structured
  `Vigil.Plugin.Error`. Reconnects transparently if the cached connection is dead.
  """
  @spec run(GenServer.server(), String.t(), String.t(), timeout()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(pool, host, command, timeout \\ @default_timeout) do
    GenServer.call(pool, {:run, host, command, timeout}, :infinity)
  end

  ## GenServer

  @impl true
  def init(opts) do
    state = %{
      integration_id: Keyword.fetch!(opts, :integration_id),
      transport: Keyword.fetch!(opts, :transport),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      host_resolver: Keyword.get(opts, :host_resolver, fn _host -> [] end),
      conns: %{}
    }

    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_call({:run, host, command, timeout}, _from, state) do
    case ensure_connection(state, host) do
      {:ok, conn, state} ->
        case state.transport.exec(conn, command, timeout) do
          {:ok, result} ->
            {:reply, {:ok, result}, state}

          {:error, reason} ->
            # The connection is presumed dead — drop it, reconnect, retry once.
            state = drop(state, host)
            retry(state, host, command, timeout, reason)
        end

      {:error, reason} ->
        {:reply, {:error, connect_error(reason)}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.conns, fn {_host, conn} -> safe_close(state.transport, conn) end)
    :ok
  end

  ## Internal

  defp retry(state, host, command, timeout, original_reason) do
    with {:ok, conn, state} <- ensure_connection(state, host),
         {:ok, result} <- state.transport.exec(conn, command, timeout) do
      {:reply, {:ok, result}, state}
    else
      {:error, %Error{}} = err ->
        {:reply, err, drop(state, host)}

      {:error, reason} ->
        Logger.warning("[ssh:pool] exec on #{host} failed after reconnect: #{inspect(reason)}")
        {:reply, {:error, exec_error(original_reason)}, drop(state, host)}
    end
  end

  defp ensure_connection(%{conns: conns} = state, host) do
    case Map.fetch(conns, host) do
      {:ok, conn} ->
        {:ok, conn, state}

      :error ->
        opts = Keyword.merge(state.transport_opts, state.host_resolver.(host))

        case state.transport.connect(host, opts) do
          {:ok, conn} -> {:ok, conn, %{state | conns: Map.put(conns, host, conn)}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp drop(%{conns: conns, transport: transport} = state, host) do
    case Map.pop(conns, host) do
      {nil, _} -> state
      {conn, rest} -> safe_close(transport, conn) && %{state | conns: rest}
    end
  end

  defp safe_close(transport, conn) do
    transport.close(conn)
    true
  rescue
    _ -> true
  end

  defp connect_error(reason) do
    %Error{
      category: :transient_external,
      message: "SSH connection failed: #{inspect(reason)}",
      detail: %{reason: reason},
      retriable?: true,
      upstream_fault?: true
    }
  end

  defp exec_error(reason) do
    %Error{
      category: :transient_external,
      message: "SSH command failed: #{inspect(reason)}",
      detail: %{reason: reason},
      retriable?: true,
      upstream_fault?: true
    }
  end

  defp gen_opts(opts) do
    case Keyword.get(opts, :name) do
      nil -> []
      name -> [name: name]
    end
  end
end

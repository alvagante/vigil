defmodule Vigil.Core.Execution.Stream do
  @moduledoc """
  One GenServer per `execution_group_id`. Owns the plugin runner, buffers
  per-target output chunks, broadcasts on PubSub, and persists the final
  transcript to each `executions` row on completion (design §6.2.4).

  ## Option A replay note (to be addressed in #15)
  Live broadcast is delivered to PubSub subscribers. Replay of output for a
  user who joins mid-execution is NOT implemented here — that requires the
  in-memory spool and ack-window from ADR-0007 §STR-103/201/202, which land
  with the durability work in issue #15.
  """

  use GenServer, restart: :temporary
  require Logger

  alias Vigil.Core.Execution.Record
  alias Vigil.Repo

  @transcript_cap_bytes 50 * 1024 * 1024
  @truncation_marker "\n[TRANSCRIPT TRUNCATED: output exceeded the 50 MB inline cap]\n"

  ## Public API

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @doc """
  Caps `data` at `cap` bytes. When the cap is exceeded, the excess is replaced
  with an explicit truncation marker so consumers know output was lost.
  """
  def cap_transcript(data, cap \\ @transcript_cap_bytes) when is_binary(data) do
    if byte_size(data) > cap do
      binary_part(data, 0, cap) <> @truncation_marker
    else
      data
    end
  end

  ## GenServer callbacks

  @impl GenServer
  @default_wall_clock_ms 1_800_000
  @default_idle_ms 300_000

  def init(args) do
    timeout = Map.get(args, :timeout, %{})

    state = %{
      runner_module: args.runner_module,
      integration_id: args.integration_id,
      artifact: args.artifact,
      group_id: args.group_id,
      # %{execution_id => %{node_id: node_id}}
      targets: Map.new(args.targets, fn t -> {t.execution_id, t} end),
      # %{execution_id => [chunk, ...]}  (prepended; reversed on finalize)
      buffers: %{},
      # %{execution_id => %{exit_status, duration_ms}}
      finished: %{},
      runner_ref: nil,
      wall_clock_ms: Map.get(timeout, :wall_clock_ms, @default_wall_clock_ms),
      idle_ms: Map.get(timeout, :idle_ms, @default_idle_ms),
      idle_timer: nil,
      wall_clock_timer: nil,
      last_chunk_at: nil
    }

    {:ok, state, {:continue, :start_runner}}
  end

  @impl GenServer
  def handle_continue(:start_runner, state) do
    targets_list = Map.values(state.targets)

    case state.runner_module.start(
           state.integration_id,
           state.artifact,
           targets_list,
           %{stream_pid: self()}
         ) do
      {:ok, runner_ref} ->
        wc_timer = Process.send_after(self(), :wall_clock_timeout, state.wall_clock_ms)
        idle_timer = Process.send_after(self(), :idle_timeout, state.idle_ms)

        {:noreply,
         %{state | runner_ref: runner_ref, wall_clock_timer: wc_timer, idle_timer: idle_timer}}

      {:error, reason} ->
        Logger.warning("[Execution.Stream] runner start failed: #{inspect(reason)}")
        mark_all_failed_to_start(state)
        {:stop, :normal, state}
    end
  end

  @impl GenServer
  def handle_info({:runner_chunk, execution_id, _kind, data}, state) do
    Phoenix.PubSub.broadcast(
      Vigil.PubSub,
      "execution_stream:#{execution_id}",
      {:chunk, execution_id, data}
    )

    buffers = Map.update(state.buffers, execution_id, [data], &[data | &1])

    # Reset idle timer on any chunk.
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    idle_timer = Process.send_after(self(), :idle_timeout, state.idle_ms)

    {:noreply,
     %{state | buffers: buffers, idle_timer: idle_timer, last_chunk_at: System.monotonic_time()}}
  end

  def handle_info({:runner_target_done, execution_id, meta}, state) do
    finished = Map.put(state.finished, execution_id, meta)
    {:noreply, %{state | finished: finished}}
  end

  def handle_info({:runner_done, _summary}, state) do
    cancel_timers(state)
    persist_all(state)
    {:stop, :normal, state}
  end

  def handle_info(:wall_clock_timeout, state) do
    Logger.info("[Execution.Stream] wall-clock timeout for group #{state.group_id}")
    abort_runner(state)
    mark_all_timed_out(state)
    {:stop, :normal, state}
  end

  def handle_info(:idle_timeout, state) do
    Logger.info("[Execution.Stream] idle timeout for group #{state.group_id}")
    abort_runner(state)
    mark_all_timed_out(state)
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[Execution.Stream] unhandled: #{inspect(msg)}")
    {:noreply, state}
  end

  ## Internal

  defp cancel_timers(state) do
    if state.wall_clock_timer, do: Process.cancel_timer(state.wall_clock_timer)
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
  end

  defp abort_runner(%{runner_module: mod, runner_ref: ref}) when not is_nil(ref) do
    try do
      mod.abort(ref)
    rescue
      _ -> :ok
    end
  end

  defp abort_runner(_state), do: :ok

  defp mark_all_timed_out(state) do
    now = DateTime.utc_now()

    Enum.each(state.targets, fn {exec_id, _target} ->
      case Repo.get(Record, exec_id) do
        nil ->
          :ok

        record ->
          record
          |> Ecto.Changeset.change(outcome: "timed_out", streaming_state: "closed", ended_at: now)
          |> Repo.update!()
      end
    end)
  end

  defp persist_all(state) do
    Enum.each(state.targets, fn {exec_id, _target} ->
      transcript =
        state.buffers
        |> Map.get(exec_id, [])
        |> Enum.reverse()
        |> IO.iodata_to_binary()
        |> cap_transcript()

      meta = Map.get(state.finished, exec_id, %{exit_status: nil, duration_ms: nil})

      case Repo.get(Record, exec_id) do
        nil ->
          :ok

        record ->
          record
          |> Record.finalize_changeset(meta, transcript)
          |> Repo.update!()

          Phoenix.PubSub.broadcast(
            Vigil.PubSub,
            "execution_stream:#{exec_id}",
            {:ended, exec_id, if(meta.exit_status == 0, do: :ok, else: :failed)}
          )
      end
    end)
  end

  defp mark_all_failed_to_start(state) do
    Enum.each(Map.keys(state.targets), fn exec_id ->
      case Repo.get(Record, exec_id) do
        nil -> :ok
        record -> record |> Ecto.Changeset.change(outcome: "failed_to_start") |> Repo.update!()
      end
    end)
  end
end

defmodule Vigil.Core.Execution.Stream do
  @moduledoc """
  One GenServer per `execution_group_id`. Owns the plugin runner, per-target
  live spool with monotonic positions, PubSub broadcast, and final transcript
  persistence (design §6.2.4, ADR-0007).

  Broadcast shape: `{:chunk, execution_id, kind, position, text}`.
  Replay: `get_buffer/3` returns `[{pos, kind, text}]` from a given position.
  """

  use GenServer, restart: :temporary
  require Logger

  alias Vigil.Core.Execution.Record
  alias Vigil.Repo

  @transcript_cap_bytes 50 * 1024 * 1024
  @truncation_marker "\n[TRANSCRIPT TRUNCATED: output exceeded the 50 MB inline cap]\n"

  ## Public API

  def via(execution_group_id),
    do: {:via, Registry, {Vigil.Core.Execution.Registry, execution_group_id}}

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: via(args.group_id))
  end

  @doc "Returns buffered chunks for `execution_id` since `since_position` (0 = from start)."
  def get_buffer(execution_group_id, execution_id, since_position) do
    GenServer.call(via(execution_group_id), {:get_buffer, execution_id, since_position})
  end

  @doc "Acknowledges that `subscriber_pid` has rendered output up to `position` for `execution_id`."
  def ack(execution_group_id, execution_id, subscriber_pid, position) do
    GenServer.cast(via(execution_group_id), {:ack, execution_id, subscriber_pid, position})
    :ok
  end

  @doc "Flushes in-memory spool to `partial_transcript` for all targets. Called by the Supervisor on SIGTERM."
  def drain(pid, _deadline_ms) do
    GenServer.call(pid, :drain)
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
  @default_grace_timer_ms 60_000
  @default_checkpoint_interval_ms 30_000

  def init(args) do
    timeout = Map.get(args, :timeout, %{})

    state = %{
      runner_module: args.runner_module,
      integration_id: args.integration_id,
      artifact: args.artifact,
      group_id: args.group_id,
      targets: Map.new(args.targets, fn t -> {t.execution_id, t} end),
      # %{execution_id => [chunk, ...]}  (prepended; reversed on finalize)
      buffers: %{},
      # %{execution_id => [{pos, kind, text}]}  (prepended; reversed on read)
      spool: %{},
      # %{execution_id => integer}  monotonic counter
      spool_position: %{},
      # %{execution_id => non_neg_integer | :capped}  byte accumulator; :capped = truncated
      spool_bytes: %{},
      # %{subscriber_pid => %{execution_id => last_acked_position}}
      subscriber_ack: %{},
      finished: %{},
      runner_ref: nil,
      spool_cap_bytes: Map.get(args, :spool_cap_bytes, @transcript_cap_bytes),
      wall_clock_ms: Map.get(timeout, :wall_clock_ms, @default_wall_clock_ms),
      idle_ms: Map.get(timeout, :idle_ms, @default_idle_ms),
      grace_timer_ms: Map.get(timeout, :grace_timer_ms, @default_grace_timer_ms),
      checkpoint_interval_ms:
        Map.get(timeout, :checkpoint_interval_ms, @default_checkpoint_interval_ms),
      idle_timer: nil,
      wall_clock_timer: nil,
      grace_timer: nil,
      checkpoint_timer: nil,
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
        cp_timer = Process.send_after(self(), :checkpoint, state.checkpoint_interval_ms)

        {:noreply,
         %{state
           | runner_ref: runner_ref,
             wall_clock_timer: wc_timer,
             idle_timer: idle_timer,
             checkpoint_timer: cp_timer
         }}

      {:error, reason} ->
        Logger.warning("[Execution.Stream] runner start failed: #{inspect(reason)}")
        mark_all_failed_to_start(state)
        {:stop, :normal, state}
    end
  end

  @impl GenServer
  def handle_info({:runner_chunk, execution_id, kind, data}, state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    idle_timer = Process.send_after(self(), :idle_timeout, state.idle_ms)
    base_state = %{state | idle_timer: idle_timer, last_chunk_at: System.monotonic_time()}

    case Map.get(state.spool_bytes, execution_id, 0) do
      :capped ->
        {:noreply, base_state}

      current_bytes ->
        pos = Map.get(state.spool_position, execution_id, 0) + 1
        new_bytes = current_bytes + byte_size(data)

        {emit_data, emit_kind, spool_bytes} =
          if new_bytes > state.spool_cap_bytes do
            {@truncation_marker, :stderr,
             Map.put(state.spool_bytes, execution_id, :capped)}
          else
            {data, kind, Map.put(state.spool_bytes, execution_id, new_bytes)}
          end

        Phoenix.PubSub.broadcast(
          Vigil.PubSub,
          "execution_stream:#{execution_id}",
          {:chunk, execution_id, emit_kind, pos, emit_data}
        )

        spool =
          Map.update(
            state.spool,
            execution_id,
            [{pos, emit_kind, emit_data}],
            &[{pos, emit_kind, emit_data} | &1]
          )

        {:noreply,
         %{base_state
           | spool: spool,
             spool_position: Map.put(state.spool_position, execution_id, pos),
             buffers: Map.update(state.buffers, execution_id, [emit_data], &[emit_data | &1]),
             spool_bytes: spool_bytes
         }}
    end
  end

  def handle_info({:runner_target_done, execution_id, meta}, state) do
    finished = Map.put(state.finished, execution_id, meta)
    {:noreply, %{state | finished: finished}}
  end

  def handle_info({:runner_done, _summary}, state) do
    cancel_timers(state)
    persist_all(state)
    timer = Process.send_after(self(), :grace_expired, state.grace_timer_ms)
    # Clear buffers so any :checkpoint already queued in the mailbox becomes a no-op.
    {:noreply, %{state | grace_timer: timer, buffers: %{}}}
  end

  def handle_info(:grace_expired, state) do
    {:stop, :normal, state}
  end

  def handle_info(:checkpoint, state) do
    persist_partial_transcripts(state)
    cp_timer = Process.send_after(self(), :checkpoint, state.checkpoint_interval_ms)
    {:noreply, %{state | checkpoint_timer: cp_timer}}
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

  @impl GenServer
  def handle_call({:get_buffer, execution_id, since_position}, _from, state) do
    chunks =
      Map.get(state.spool, execution_id, [])
      |> Enum.reverse()
      |> Enum.drop_while(fn {pos, _, _} -> pos <= since_position end)

    {:reply, chunks, state}
  end

  def handle_call(:drain, _from, state) do
    persist_partial_transcripts(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:ack, execution_id, subscriber_pid, position}, state) do
    current = get_in(state.subscriber_ack, [subscriber_pid, execution_id]) || 0

    subscriber_ack =
      if position > current do
        put_in(state.subscriber_ack, [Access.key(subscriber_pid, %{}), execution_id], position)
      else
        state.subscriber_ack
      end

    {:noreply, %{state | subscriber_ack: subscriber_ack}}
  end

  @impl GenServer
  def terminate(:normal, _state), do: :ok

  def terminate(_reason, state) do
    persist_partial_transcripts(state)
    :ok
  end

  ## Internal

  defp cancel_timers(state) do
    if state.wall_clock_timer, do: Process.cancel_timer(state.wall_clock_timer)
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    if state.grace_timer, do: Process.cancel_timer(state.grace_timer)
    if state.checkpoint_timer, do: Process.cancel_timer(state.checkpoint_timer)
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
          |> Ecto.Changeset.change(partial_transcript: nil)
          |> Repo.update!()

          Phoenix.PubSub.broadcast(
            Vigil.PubSub,
            "execution_stream:#{exec_id}",
            {:ended, exec_id, if(meta.exit_status == 0, do: :ok, else: :failed)}
          )
      end
    end)
  end

  defp persist_partial_transcripts(state) do
    Enum.each(state.targets, fn {exec_id, _target} ->
      raw =
        state.buffers
        |> Map.get(exec_id, [])
        |> Enum.reverse()
        |> IO.iodata_to_binary()

      if byte_size(raw) > 0 do
        gzipped = :zlib.gzip(raw)

        case Repo.get(Record, exec_id) do
          nil -> :ok
          record -> record |> Ecto.Changeset.change(partial_transcript: gzipped) |> Repo.update!()
        end
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

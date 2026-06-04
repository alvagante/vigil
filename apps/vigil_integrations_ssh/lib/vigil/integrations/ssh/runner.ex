defmodule Vigil.Integrations.SSH.Runner do
  @moduledoc """
  SSH execution runner (SSH-3xx). Spawns a process per execution group that
  iterates targets serially via the integration's ConnectionPool, sends the
  runner protocol messages to the Stream GenServer, and exits on completion.

  Batch exec: stdout is delivered as a single chunk when the command completes.
  Incremental streaming (via Transport.stream_exec) is deferred.
  """

  @behaviour Vigil.Plugin.Execution.Runner

  alias Vigil.Integrations.SSH.ConnectionPool

  @impl Vigil.Plugin.Execution.Runner
  def start(integration_id, artifact, targets, opts) do
    stream_pid = Map.get(opts, :stream_pid)
    pool = Map.get(opts, :pool) || pool_ref(integration_id)
    command = artifact[:text] || artifact["text"] || ""

    pid = spawn(fn -> run_all(pool, command, targets, stream_pid) end)
    {:ok, pid}
  end

  @impl Vigil.Plugin.Execution.Runner
  def abort(runner_pid) do
    if is_pid(runner_pid) and Process.alive?(runner_pid) do
      Process.exit(runner_pid, :kill)
    end

    :ok
  end

  defp run_all(pool, command, targets, stream_pid) do
    Enum.each(targets, fn target ->
      start_ms = System.monotonic_time(:millisecond)

      case ConnectionPool.run(pool, target.node_id, command) do
        {:ok, %{exit_status: status, stdout: out}} ->
          if stream_pid && byte_size(out) > 0 do
            send(stream_pid, {:runner_chunk, target.execution_id, :text, out})
          end

          duration_ms = System.monotonic_time(:millisecond) - start_ms

          maybe_send(
            stream_pid,
            {:runner_target_done, target.execution_id,
             %{exit_status: status, duration_ms: duration_ms}}
          )

        {:error, _reason} ->
          duration_ms = System.monotonic_time(:millisecond) - start_ms

          maybe_send(
            stream_pid,
            {:runner_target_done, target.execution_id,
             %{exit_status: -1, duration_ms: duration_ms}}
          )
      end
    end)

    maybe_send(stream_pid, {:runner_done, %{}})
  end

  defp maybe_send(nil, _msg), do: :ok
  defp maybe_send(pid, msg), do: send(pid, msg)

  defp pool_ref(integration_id) do
    {:via, Registry, {Vigil.Plugin.Registry, {:ssh_pool, integration_id}}}
  end
end

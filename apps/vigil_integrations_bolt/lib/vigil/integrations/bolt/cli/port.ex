defmodule Vigil.Integrations.Bolt.CLI.Port do
  @moduledoc """
  Real Bolt CLI adapter using an Erlang Port (EXEC-CLI-001, BOLT-301, BOLT-302).

  Opens a port for the `bolt` executable, collects stdout, and enforces both
  wall-clock and idle timeouts.  Stderr is discarded; `bolt --format json`
  writes structured results to stdout, and non-zero exit status covers fatal
  errors.
  """

  @behaviour Vigil.Integrations.Bolt.CLI

  @default_wall_clock_ms 3_600_000
  @default_idle_ms 300_000

  @impl Vigil.Integrations.Bolt.CLI
  def run(executable, args, opts) do
    wall_clock_ms = Keyword.get(opts, :wall_clock_ms, @default_wall_clock_ms)
    idle_ms = Keyword.get(opts, :idle_ms, @default_idle_ms)

    case System.find_executable(executable) do
      nil ->
        {:error, :not_found}

      exec_path ->
        port =
          Port.open({:spawn_executable, exec_path}, [
            :binary,
            :exit_status,
            {:args, args}
          ])

        deadline_ms = System.monotonic_time(:millisecond) + wall_clock_ms
        collect(port, [], deadline_ms, idle_ms, System.monotonic_time(:millisecond))
    end
  end

  defp collect(port, acc, deadline_ms, idle_ms, last_data_ts) do
    now = System.monotonic_time(:millisecond)
    wall_remaining = deadline_ms - now
    idle_remaining = last_data_ts + idle_ms - now
    timeout = max(0, min(wall_remaining, idle_remaining))

    receive do
      {^port, {:data, chunk}} ->
        collect(port, [chunk | acc], deadline_ms, idle_ms, System.monotonic_time(:millisecond))

      {^port, {:exit_status, status}} ->
        stdout = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, %{exit_status: status, stdout: stdout, stderr: ""}}
    after
      timeout ->
        # Get OS PID before closing the port; Port.close alone does not signal the process.
        case Port.info(port, :os_pid) do
          {:os_pid, os_pid} -> :os.cmd(String.to_charlist("kill -9 #{os_pid}"))
          nil -> :ok
        end

        Port.close(port)
        {:error, :timeout}
    end
  end
end

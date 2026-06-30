defmodule Vigil.Integrations.Ansible.CLI.Port do
  @moduledoc """
  Production CLI transport: runs ansible binaries via `System.cmd/3`.

  Wall-clock timeouts use a Task with `Task.yield/2`; idle timeouts are not
  enforced at this layer (they require line-by-line streaming, deferred).
  """

  @behaviour Vigil.Integrations.Ansible.CLI

  @default_wall_clock_ms 60_000

  @impl true
  def run(executable, args, opts) do
    wall_clock_ms = Keyword.get(opts, :wall_clock_ms, @default_wall_clock_ms)
    env = Keyword.get(opts, :env, [])

    task =
      Task.async(fn ->
        System.cmd(executable, args,
          env: env,
          stderr_to_stdout: true,
          into: ""
        )
      end)

    case Task.yield(task, wall_clock_ms) || Task.shutdown(task) do
      {:ok, {stdout, exit_status}} ->
        {:ok, %{exit_status: exit_status, stdout: stdout}}

      nil ->
        {:error, :timeout}

      {:exit, {:error, :enoent}} ->
        {:error, :not_found}

      {:exit, reason} ->
        {:error, reason}
    end
  rescue
    ErlangError -> {:error, :not_found}
  end
end

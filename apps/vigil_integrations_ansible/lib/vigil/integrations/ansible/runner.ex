defmodule Vigil.Integrations.Ansible.Runner do
  @moduledoc """
  Ansible execution runner (ANS-401, ANS-402, ANS-405).

  Spawns a process per execution that invokes `ansible` (ad-hoc) or
  `ansible-playbook` (playbook), delivers per-target chunks to the Stream
  GenServer, and signals completion via the runner protocol.

  Note: structured line-by-line JSON streaming (ANSIBLE_STDOUT_CALLBACK=json)
  is deferred. This slice parses the full stdout after completion.
  """

  @behaviour Vigil.Plugin.Execution.Runner

  alias Vigil.Integrations.Ansible.Server

  @default_wall_clock_ms 3_600_000
  @default_idle_ms 300_000
  @default_concurrency 5

  @impl true
  def start(integration_id, artifact, targets, opts) do
    stream_pid = Map.get(opts, :stream_pid)

    with {:ok, config} <- Server.get_config(integration_id) do
      max = Map.get(config, "concurrency", @default_concurrency)

      case Server.acquire_slot(integration_id, max) do
        :ok ->
          pid =
            spawn(fn ->
              try do
                run(integration_id, config, artifact, targets, stream_pid)
              after
                Server.release_slot(integration_id)
              end
            end)

          {:ok, pid}

        {:error, :at_capacity} ->
          {:error, :at_capacity}
      end
    else
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @impl true
  def abort(runner_pid) do
    if is_pid(runner_pid) and Process.alive?(runner_pid) do
      Process.exit(runner_pid, :kill)
    end

    :ok
  end

  defp run(_integration_id, config, artifact, targets, stream_pid) do
    if targets == [] do
      maybe_send(stream_pid, {:runner_done, %{}})
      :ok
    else
      case artifact_kind(artifact) do
        :command -> run_adhoc(config, artifact, targets, stream_pid)
        :playbook -> run_playbook(config, artifact, targets, stream_pid)
        _ -> maybe_send(stream_pid, {:runner_done, %{error: :unknown_artifact_kind}})
      end
    end
  end

  defp run_adhoc(config, artifact, targets, stream_pid) do
    cli = cli_module(config)
    cli_opts = cli_opts(config)
    ansible_exe = Map.get(config, "ansible_executable", "ansible")
    inventory = Map.get(config, "inventory", "localhost,")
    module = artifact[:module] || artifact["module"] || "shell"
    cmd_args = artifact[:text] || artifact["text"] || ""
    target_pattern = targets_to_pattern(targets)
    forks = Map.get(config, "forks", @default_concurrency)
    wall_clock_ms = Map.get(config, "timeout.wall_clock", @default_wall_clock_ms)
    idle_ms = Map.get(config, "timeout.idle", @default_idle_ms)

    args = [
      target_pattern,
      "-i", inventory,
      "-m", module,
      "-a", cmd_args,
      "--forks", to_string(forks)
    ]

    start_ms = System.monotonic_time(:millisecond)

    case cli.run(ansible_exe, args, Keyword.merge(cli_opts, wall_clock_ms: wall_clock_ms, idle_ms: idle_ms)) do
      {:ok, %{exit_status: exit_status, stdout: stdout}} ->
        duration_ms = System.monotonic_time(:millisecond) - start_ms

        Enum.each(targets, fn target ->
          execution_id = target.execution_id || target[:execution_id]
          if byte_size(stdout) > 0,
            do: maybe_send(stream_pid, {:runner_chunk, execution_id, :text, stdout})
          maybe_send(stream_pid, {:runner_target_done, execution_id, %{exit_status: exit_status, duration_ms: duration_ms}})
        end)

        maybe_send(stream_pid, {:runner_done, %{}})

      {:error, :not_found} ->
        deliver_error("ansible executable not found", targets, stream_pid)

      {:error, :timeout} ->
        duration_ms = System.monotonic_time(:millisecond) - start_ms
        deliver_timeout(duration_ms, targets, stream_pid)

      {:error, reason} ->
        deliver_error(inspect(reason), targets, stream_pid)
    end
  end

  defp run_playbook(config, artifact, targets, stream_pid) do
    cli = cli_module(config)
    cli_opts = cli_opts(config)
    playbook_exe = Map.get(config, "ansible_playbook_executable", "ansible-playbook")
    inventory = Map.get(config, "inventory", "localhost,")
    playbook_path = artifact[:path] || artifact["path"] || artifact[:name] || artifact["name"] || ""
    extra_vars = artifact[:extra_vars] || artifact["extra_vars"]
    target_pattern = targets_to_pattern(targets)
    forks = Map.get(config, "forks", @default_concurrency)
    wall_clock_ms = Map.get(config, "timeout.wall_clock", @default_wall_clock_ms)
    idle_ms = Map.get(config, "timeout.idle", @default_idle_ms)

    args =
      ["-i", inventory, "--forks", to_string(forks)] ++
      (if target_pattern != "all", do: ["--limit", target_pattern], else: []) ++
      extra_vars_args(extra_vars) ++
      [playbook_path]

    start_ms = System.monotonic_time(:millisecond)

    case cli.run(playbook_exe, args, Keyword.merge(cli_opts, wall_clock_ms: wall_clock_ms, idle_ms: idle_ms)) do
      {:ok, %{exit_status: exit_status, stdout: stdout}} ->
        duration_ms = System.monotonic_time(:millisecond) - start_ms

        Enum.each(targets, fn target ->
          execution_id = target.execution_id || target[:execution_id]
          if byte_size(stdout) > 0,
            do: maybe_send(stream_pid, {:runner_chunk, execution_id, :text, stdout})
          maybe_send(stream_pid, {:runner_target_done, execution_id, %{exit_status: exit_status, duration_ms: duration_ms}})
        end)

        maybe_send(stream_pid, {:runner_done, %{}})

      {:error, :not_found} ->
        deliver_error("ansible-playbook executable not found", targets, stream_pid)

      {:error, :timeout} ->
        duration_ms = System.monotonic_time(:millisecond) - start_ms
        deliver_timeout(duration_ms, targets, stream_pid)

      {:error, reason} ->
        deliver_error(inspect(reason), targets, stream_pid)
    end
  end

  defp extra_vars_args(nil), do: []
  defp extra_vars_args(ev) when is_map(ev), do: ["--extra-vars", Jason.encode!(ev)]
  defp extra_vars_args(ev) when is_binary(ev), do: ["--extra-vars", ev]
  defp extra_vars_args(_), do: []

  defp targets_to_pattern([]), do: "all"
  defp targets_to_pattern(targets) do
    targets
    |> Enum.map(fn t -> t.node_id || t[:node_id] || "all" end)
    |> Enum.join(",")
  end

  defp deliver_error(msg, targets, stream_pid) do
    Enum.each(targets, fn target ->
      execution_id = target.execution_id || target[:execution_id]
      maybe_send(stream_pid, {:runner_chunk, execution_id, :text, "error: #{msg}\n"})
      maybe_send(stream_pid, {:runner_target_done, execution_id, %{exit_status: -1, duration_ms: 0}})
    end)
    maybe_send(stream_pid, {:runner_done, %{error: msg}})
  end

  defp deliver_timeout(duration_ms, targets, stream_pid) do
    Enum.each(targets, fn target ->
      execution_id = target.execution_id || target[:execution_id]
      maybe_send(stream_pid, {:runner_chunk, execution_id, :text, "execution timed out\n"})
      maybe_send(stream_pid, {:runner_target_done, execution_id, %{exit_status: -1, duration_ms: duration_ms}})
    end)
    maybe_send(stream_pid, {:runner_done, %{error: :timeout}})
  end

  defp artifact_kind(%{kind: k}), do: k
  defp artifact_kind(%{"kind" => k}), do: String.to_existing_atom(k)
  defp artifact_kind(_), do: :command

  defp cli_module(config), do: Map.get(config, "cli_module", Vigil.Integrations.Ansible.CLI.Port)

  defp cli_opts(config) do
    case Map.get(config, "cli_opts") do
      nil -> []
      opts when is_list(opts) -> opts
      _ -> []
    end
  end

  defp maybe_send(nil, _), do: :ok
  defp maybe_send(pid, msg), do: send(pid, msg)
end

defmodule Vigil.Integrations.Bolt.Runner do
  @moduledoc """
  Bolt execution runner (BOLT-201, BOLT-205, BOLT-301, BOLT-302, BOLT-303).

  Spawns a process per execution that invokes `bolt command run --format json`,
  streams per-target results back to the Stream GenServer via runner protocol
  messages, enforces timeouts, and releases the concurrency slot on exit.
  """

  @behaviour Vigil.Plugin.Execution.Runner

  alias Vigil.Integrations.Bolt.Server

  @default_wall_clock_ms 3_600_000
  @default_idle_ms 300_000
  @default_concurrency 10

  @impl Vigil.Plugin.Execution.Runner
  def start(integration_id, artifact, targets, opts) do
    stream_pid = Map.get(opts, :stream_pid)

    with {:ok, config} <- Server.get_config(integration_id) do
      max = Map.get(config, "concurrency", @default_concurrency)

      case Server.acquire_slot(integration_id, max) do
        :ok ->
          pid =
            spawn(fn ->
              try do
                run_targets(integration_id, config, artifact, targets, stream_pid)
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

  @impl Vigil.Plugin.Execution.Runner
  def abort(runner_pid) do
    if is_pid(runner_pid) and Process.alive?(runner_pid) do
      Process.exit(runner_pid, :kill)
    end

    :ok
  end

  defp run_targets(_integration_id, config, artifact, targets, stream_pid) do
    target_names = Enum.map(targets, fn t -> t.node_id || t[:node_id] end)
    target_list = Enum.join(target_names, ",")

    bolt_exe = Map.get(config, "bolt_executable", "bolt")
    project_dir = Map.get(config, "project_dir", ".")
    wall_clock_ms = Map.get(config, "wall_clock_ms", @default_wall_clock_ms)
    idle_ms = Map.get(config, "idle_ms", @default_idle_ms)
    cli_mod = cli_module(config)
    cli_opts = cli_opts(config, wall_clock_ms: wall_clock_ms, idle_ms: idle_ms)

    args = build_args(artifact, target_list, project_dir)

    start_ms = System.monotonic_time(:millisecond)
    plan? = plan_artifact?(artifact)

    case cli_mod.run(bolt_exe, args, cli_opts) do
      {:ok, %{exit_status: exit_status, stdout: json}} ->
        duration_ms = System.monotonic_time(:millisecond) - start_ms

        if plan? do
          deliver_plan_result(json, exit_status, targets, stream_pid, duration_ms)
        else
          deliver_results(json, targets, stream_pid, duration_ms)
        end

      {:error, :not_found} ->
        targets
        |> Enum.each(fn t ->
          maybe_send(
            stream_pid,
            {:runner_chunk, t.execution_id, :text, "bolt: command not found\n"}
          )

          maybe_send(
            stream_pid,
            {:runner_target_done, t.execution_id, %{exit_status: -1, duration_ms: 0}}
          )
        end)

        maybe_send(stream_pid, {:runner_done, %{error: :bolt_not_found}})

      {:error, :timeout} ->
        duration_ms = System.monotonic_time(:millisecond) - start_ms

        targets
        |> Enum.each(fn t ->
          maybe_send(stream_pid, {:runner_chunk, t.execution_id, :text, "execution timed out\n"})

          maybe_send(
            stream_pid,
            {:runner_target_done, t.execution_id, %{exit_status: -1, duration_ms: duration_ms}}
          )
        end)

        maybe_send(stream_pid, {:runner_done, %{error: :timeout}})

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start_ms

        targets
        |> Enum.each(fn t ->
          maybe_send(
            stream_pid,
            {:runner_chunk, t.execution_id, :text, "error: #{inspect(reason)}\n"}
          )

          maybe_send(
            stream_pid,
            {:runner_target_done, t.execution_id, %{exit_status: -1, duration_ms: duration_ms}}
          )
        end)

        maybe_send(stream_pid, {:runner_done, %{error: reason}})
    end
  end

  defp plan_artifact?(%{kind: :plan}), do: true
  defp plan_artifact?(%{"kind" => "plan"}), do: true
  defp plan_artifact?(_), do: false

  defp deliver_plan_result(stdout, exit_status, targets, stream_pid, duration_ms) do
    text =
      case Jason.decode(stdout) do
        {:ok, value} when is_map(value) -> Jason.encode!(value)
        {:ok, value} -> inspect(value)
        {:error, _} -> stdout
      end

    Enum.each(targets, fn target ->
      execution_id = target.execution_id || target[:execution_id]
      if byte_size(text) > 0, do: maybe_send(stream_pid, {:runner_chunk, execution_id, :text, text})
      maybe_send(stream_pid, {:runner_target_done, execution_id, %{exit_status: exit_status, duration_ms: duration_ms}})
    end)

    maybe_send(stream_pid, {:runner_done, %{}})
  end

  defp build_args(%{kind: :command} = artifact, target_list, project_dir) do
    command = artifact[:text] || artifact["text"] || ""
    ["command", "run", command, "--targets", target_list, "--project", project_dir, "--format", "json"]
  end

  defp build_args(%{"kind" => "command"} = artifact, target_list, project_dir) do
    command = artifact["text"] || ""
    ["command", "run", command, "--targets", target_list, "--project", project_dir, "--format", "json"]
  end

  defp build_args(%{kind: :task} = artifact, target_list, project_dir) do
    name = artifact[:name] || artifact["name"] || ""
    params = artifact[:params] || artifact["params"] || %{}
    params_json = Jason.encode!(params)
    ["task", "run", name, "--params", params_json, "--targets", target_list, "--project", project_dir, "--format", "json"]
  end

  defp build_args(%{"kind" => "task"} = artifact, target_list, project_dir) do
    name = artifact["name"] || ""
    params = artifact["params"] || %{}
    params_json = Jason.encode!(params)
    ["task", "run", name, "--params", params_json, "--targets", target_list, "--project", project_dir, "--format", "json"]
  end

  defp build_args(%{kind: :plan} = artifact, _target_list, project_dir) do
    name = artifact[:name] || artifact["name"] || ""
    params = artifact[:params] || artifact["params"] || %{}
    params_json = Jason.encode!(params)
    ["plan", "run", name, "--params", params_json, "--project", project_dir, "--format", "json"]
  end

  defp build_args(%{"kind" => "plan"} = artifact, _target_list, project_dir) do
    name = artifact["name"] || ""
    params = artifact["params"] || %{}
    params_json = Jason.encode!(params)
    ["plan", "run", name, "--params", params_json, "--project", project_dir, "--format", "json"]
  end

  defp build_args(artifact, target_list, project_dir) do
    # Fallback: treat as legacy command artifact
    command = artifact[:text] || artifact["text"] || ""
    ["command", "run", command, "--targets", target_list, "--project", project_dir, "--format", "json"]
  end

  defp deliver_results(stdout, targets, stream_pid, total_duration_ms) do
    results = parse_results(stdout)

    Enum.each(targets, fn target ->
      node_id = target.node_id || target[:node_id]
      execution_id = target.execution_id || target[:execution_id]
      result = Map.get(results, node_id, %{stdout: "", exit_status: -1})

      if byte_size(result.stdout) > 0 do
        maybe_send(stream_pid, {:runner_chunk, execution_id, :text, result.stdout})
      end

      maybe_send(stream_pid, {
        :runner_target_done,
        execution_id,
        %{exit_status: result.exit_status, duration_ms: total_duration_ms}
      })
    end)

    maybe_send(stream_pid, {:runner_done, %{}})
  end

  defp parse_results(stdout) do
    case Jason.decode(stdout) do
      {:ok, %{"items" => items}} ->
        Map.new(items, fn item ->
          target = item["target"]
          value = item["value"] || %{}

          exit_code =
            cond do
              is_integer(value["exit_code"]) -> value["exit_code"]
              item["status"] == "success" -> 0
              true -> 1
            end

          text = extract_text(value)
          {target, %{stdout: text, exit_status: exit_code}}
        end)

      _ ->
        %{}
    end
  end

  defp extract_text(value) when is_map(value) do
    stdout = value["stdout"] || ""
    stderr = value["stderr"] || ""

    if stdout == "" and stderr == "" do
      Jason.encode!(value)
    else
      stdout <> stderr
    end
  end

  defp extract_text(_), do: ""

  defp cli_module(config), do: Map.get(config, "cli_module", Vigil.Integrations.Bolt.CLI.Port)

  defp cli_opts(config, extra) do
    base = Map.get(config, "cli_opts", [])
    Keyword.merge(base, extra)
  end

  defp maybe_send(nil, _msg), do: :ok
  defp maybe_send(pid, msg), do: send(pid, msg)
end

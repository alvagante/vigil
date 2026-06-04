defmodule Vigil.Integrations.Bolt do
  @moduledoc """
  Bolt integration plugin — issue #13 slice: inventory via `bolt inventory show`
  and ad-hoc command execution via `bolt command run` (PRD §8.2, design §3/§6).

  Capabilities: `:inventory`, `:execution`.
  Out of scope here: tasks, plans (#14), journal contributions (#20).

  Inventory acquisition delegates to the Bolt binary (`bolt inventory show
  --format json`) rather than parsing `inventory.yaml` directly, so that
  dynamic inventory plugins and group-config inheritance are resolved by Bolt
  itself (EXEC-CLI-002, BOLT-106).
  """

  @behaviour Vigil.Plugin
  @behaviour Vigil.Plugin.Health
  @behaviour Vigil.Plugin.Inventory
  @behaviour Vigil.Plugin.Execution.Runner

  alias Vigil.Integrations.Bolt.{Runner, Server}
  alias Vigil.Integrations.Bolt.Plan, as: BoltPlan
  alias Vigil.Integrations.Bolt.Task, as: BoltTask
  alias Vigil.Plugin.{Error, Node, Permission, Result, Schema, Source}

  @plugin_id "bolt"
  @default_bolt_exe "bolt"
  @default_wall_clock_ms 3_600_000
  @default_idle_ms 300_000

  @secret_fields ~w[password private-key token sudo-password]

  ## Vigil.Plugin contract

  @impl Vigil.Plugin
  def plugin_id, do: @plugin_id

  @impl Vigil.Plugin
  def display_name, do: "Bolt"

  @impl Vigil.Plugin
  def contract_version, do: Version.parse!("1.0.0")

  @impl Vigil.Plugin
  def capabilities, do: [:inventory, :execution]

  @impl Vigil.Plugin
  def config_schema do
    alias Vigil.Plugin.Schema.Field

    %Schema{
      fields: [
        %Field{
          name: "project_dir",
          type: :string,
          required: true,
          description: "Path to the Bolt project directory."
        },
        %Field{
          name: "bolt_executable",
          type: :string,
          required: false,
          default: @default_bolt_exe,
          description: "Path to the `bolt` binary (default: resolved from PATH)."
        },
        %Field{
          name: "inventory_file",
          type: :string,
          required: false,
          description: "Override inventory file path (default: <project_dir>/inventory.yaml)."
        },
        %Field{
          name: "default_transport",
          type: :string,
          required: false,
          description: "Default transport when not specified per-node."
        },
        %Field{
          name: "concurrency",
          type: :integer,
          required: false,
          default: 10,
          description: "Per-integration concurrent-execution limit (BOLT-303)."
        },
        %Field{
          name: "timeout.wall_clock",
          type: :integer,
          required: false,
          default: @default_wall_clock_ms,
          description: "Default wall-clock timeout per CLI invocation in ms (BOLT-301)."
        },
        %Field{
          name: "timeout.idle",
          type: :integer,
          required: false,
          default: @default_idle_ms,
          description: "Default idle timeout per CLI invocation in ms (BOLT-301)."
        }
      ]
    }
  end

  @impl Vigil.Plugin
  def defaults do
    %{
      cache_ttl: %{inventory: 900_000},
      timeouts: %{inventory: 30_000},
      concurrency: 10
    }
  end

  @impl Vigil.Plugin
  def operational_permissions do
    [
      %Permission{
        kind: :filesystem,
        description: "Reads the Bolt project directory and inventory file.",
        detail: %{}
      },
      %Permission{
        kind: :network,
        description: "Opens outbound connections to inventoried targets via the Bolt CLI."
      },
      %Permission{
        kind: :executable,
        description: "Invokes the `bolt` CLI binary on the host system (EXEC-CLI-001)."
      },
      %Permission{
        kind: :credential,
        description:
          "Uses SSH keys, WinRM credentials, and any secrets configured in the Bolt project."
      }
    ]
  end

  @impl Vigil.Plugin
  def child_spec({integration_id, config}) do
    children = [{Server, {integration_id, config}}]

    %{
      id: {:bolt_supervisor, integration_id},
      start:
        {Supervisor, :start_link,
         [children, [strategy: :one_for_one, max_restarts: 10, max_seconds: 60]]},
      type: :supervisor,
      restart: :permanent
    }
  end

  ## Vigil.Plugin.Inventory

  @impl Vigil.Plugin.Inventory
  def list_nodes(integration_id, _opts) do
    with {:ok, config} <- Server.get_config(integration_id) do
      bolt_exe = Map.get(config, "bolt_executable", @default_bolt_exe)
      project_dir = Map.get(config, "project_dir", ".")
      cli_mod = cli_module(config)
      opts = cli_opts(config)

      args = ["inventory", "show", "--detail", "--project", project_dir, "--format", "json"]

      case cli_mod.run(bolt_exe, args, opts) do
        {:ok, %{exit_status: 0, stdout: json}} ->
          case parse_inventory(json, integration_id) do
            {:ok, nodes} -> {:ok, ok_result(integration_id, nodes)}
            {:error, reason} -> {:error, parse_error(reason)}
          end

        {:ok, %{exit_status: status}} ->
          {:error, bolt_error("bolt inventory show exited #{status}")}

        {:error, :not_found} ->
          {:error,
           %Error{
             category: :configuration,
             message: "bolt executable not found — check `bolt_executable` config",
             retriable?: false
           }}

        {:error, reason} ->
          {:error, transient_error(reason)}
      end
    else
      {:error, :not_found} -> {:error, no_instance_error(integration_id)}
    end
  end

  ## Vigil.Plugin.Health

  @impl Vigil.Plugin.Health
  def health_check(integration_id) do
    case Server.get_config(integration_id) do
      {:ok, config} ->
        bolt_exe = Map.get(config, "bolt_executable", @default_bolt_exe)
        project_dir = Map.get(config, "project_dir", ".")
        cli_mod = cli_module(config)
        opts = cli_opts(config)

        args = ["inventory", "show", "--detail", "--project", project_dir, "--format", "json"]

        case cli_mod.run(bolt_exe, args, opts) do
          {:ok, %{exit_status: 0}} -> {:ok, :healthy}
          {:error, :not_found} -> {:ok, :unhealthy}
          _ -> {:ok, :unhealthy}
        end

      {:error, :not_found} ->
        {:ok, :unhealthy}
    end
  end

  ## Task discovery

  @doc "Lists available Bolt tasks with name and description (BOLT-202)."
  def list_tasks(integration_id, _opts) do
    with {:ok, config} <- Server.get_config(integration_id) do
      bolt_exe = Map.get(config, "bolt_executable", @default_bolt_exe)
      project_dir = Map.get(config, "project_dir", ".")
      cli_mod = cli_module(config)
      opts = cli_opts(config)

      args = ["task", "show", "--project", project_dir, "--format", "json"]

      case cli_mod.run(bolt_exe, args, opts) do
        {:ok, %{exit_status: 0, stdout: json}} ->
          case parse_task_list(json, integration_id) do
            {:ok, tasks} -> {:ok, ok_result(integration_id, tasks)}
            {:error, reason} -> {:error, parse_error(reason)}
          end

        {:ok, %{exit_status: status}} ->
          {:error, bolt_error("bolt task show exited #{status}")}

        {:error, :not_found} ->
          {:error,
           %Error{
             category: :configuration,
             message: "bolt executable not found — check `bolt_executable` config",
             retriable?: false
           }}

        {:error, reason} ->
          {:error, transient_error(reason)}
      end
    else
      {:error, :not_found} -> {:error, no_instance_error(integration_id)}
    end
  end

  @doc "Returns a single Bolt task with full parameter metadata (BOLT-202)."
  def show_task(integration_id, task_name, _opts) do
    with {:ok, config} <- Server.get_config(integration_id) do
      bolt_exe = Map.get(config, "bolt_executable", @default_bolt_exe)
      project_dir = Map.get(config, "project_dir", ".")
      cli_mod = cli_module(config)
      opts = cli_opts(config)

      args = ["task", "show", task_name, "--project", project_dir, "--format", "json"]

      case cli_mod.run(bolt_exe, args, opts) do
        {:ok, %{exit_status: 0, stdout: json}} ->
          case parse_task_detail(json) do
            {:ok, task} -> {:ok, ok_result(integration_id, task)}
            {:error, reason} -> {:error, parse_error(reason)}
          end

        {:ok, %{exit_status: status}} ->
          {:error, bolt_error("bolt task show #{task_name} exited #{status}")}

        {:error, :not_found} ->
          {:error,
           %Error{
             category: :configuration,
             message: "bolt executable not found — check `bolt_executable` config",
             retriable?: false
           }}

        {:error, reason} ->
          {:error, transient_error(reason)}
      end
    else
      {:error, :not_found} -> {:error, no_instance_error(integration_id)}
    end
  end

  ## Plan discovery

  @doc "Lists available Bolt plans with name and description (BOLT-204)."
  def list_plans(integration_id, _opts) do
    with {:ok, config} <- Server.get_config(integration_id) do
      bolt_exe = Map.get(config, "bolt_executable", @default_bolt_exe)
      project_dir = Map.get(config, "project_dir", ".")
      cli_mod = cli_module(config)
      opts = cli_opts(config)

      args = ["plan", "show", "--project", project_dir, "--format", "json"]

      case cli_mod.run(bolt_exe, args, opts) do
        {:ok, %{exit_status: 0, stdout: json}} ->
          case parse_plan_list(json) do
            {:ok, plans} -> {:ok, ok_result(integration_id, plans)}
            {:error, reason} -> {:error, parse_error(reason)}
          end

        {:ok, %{exit_status: status}} ->
          {:error, bolt_error("bolt plan show exited #{status}")}

        {:error, :not_found} ->
          {:error,
           %Error{
             category: :configuration,
             message: "bolt executable not found — check `bolt_executable` config",
             retriable?: false
           }}

        {:error, reason} ->
          {:error, transient_error(reason)}
      end
    else
      {:error, :not_found} -> {:error, no_instance_error(integration_id)}
    end
  end

  @doc "Returns a single Bolt plan with full parameter metadata (BOLT-204)."
  def show_plan(integration_id, plan_name, _opts) do
    with {:ok, config} <- Server.get_config(integration_id) do
      bolt_exe = Map.get(config, "bolt_executable", @default_bolt_exe)
      project_dir = Map.get(config, "project_dir", ".")
      cli_mod = cli_module(config)
      opts = cli_opts(config)

      args = ["plan", "show", plan_name, "--project", project_dir, "--format", "json"]

      case cli_mod.run(bolt_exe, args, opts) do
        {:ok, %{exit_status: 0, stdout: json}} ->
          case parse_plan_detail(json) do
            {:ok, plan} -> {:ok, ok_result(integration_id, plan)}
            {:error, reason} -> {:error, parse_error(reason)}
          end

        {:ok, %{exit_status: status}} ->
          {:error, bolt_error("bolt plan show #{plan_name} exited #{status}")}

        {:error, :not_found} ->
          {:error,
           %Error{
             category: :configuration,
             message: "bolt executable not found — check `bolt_executable` config",
             retriable?: false
           }}

        {:error, reason} ->
          {:error, transient_error(reason)}
      end
    else
      {:error, :not_found} -> {:error, no_instance_error(integration_id)}
    end
  end

  ## Vigil.Plugin.Execution.Runner

  @impl Vigil.Plugin.Execution.Runner
  def start(integration_id, artifact, targets, opts) do
    Runner.start(integration_id, artifact, targets, opts)
  end

  @impl Vigil.Plugin.Execution.Runner
  def abort(runner_ref) do
    Runner.abort(runner_ref)
  end

  ## Internal

  defp parse_plan_list(json) do
    case Jason.decode(json) do
      {:ok, %{"plans" => plans}} ->
        result =
          Enum.map(plans, fn
            [name, description] -> %BoltPlan{name: name, description: description}
            [name] -> %BoltPlan{name: name, description: nil}
          end)

        {:ok, result}

      {:ok, _unexpected} ->
        {:error, "unexpected bolt plan show output shape"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_plan_detail(json) do
    case Jason.decode(json) do
      {:ok, %{"name" => name} = raw} ->
        description = raw["description"]

        params =
          (raw["parameters"] || %{})
          |> Enum.map(fn {param_name, meta} ->
            type = meta["type"] || ""
            required = not String.starts_with?(type, "Optional[")

            %{
              name: param_name,
              type: type,
              required: required,
              sensitive: meta["sensitive"] || false,
              description: meta["description"]
            }
          end)
          |> Enum.sort_by(& &1.name)

        {:ok, %BoltPlan{name: name, description: description, parameters: params}}

      {:ok, _unexpected} ->
        {:error, "unexpected bolt plan show <name> output shape"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_task_detail(json) do
    case Jason.decode(json) do
      {:ok, %{"name" => name} = raw} ->
        description = get_in(raw, ["metadata", "description"])

        params =
          (get_in(raw, ["metadata", "parameters"]) || %{})
          |> Enum.map(fn {param_name, meta} ->
            type = meta["type"] || ""
            required = not String.starts_with?(type, "Optional[")

            %{
              name: param_name,
              type: type,
              required: required,
              sensitive: false,
              description: meta["description"]
            }
          end)
          |> Enum.sort_by(& &1.name)

        {:ok, %BoltTask{name: name, description: description, parameters: params}}

      {:ok, _unexpected} ->
        {:error, "unexpected bolt task show <name> output shape"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_task_list(json, _integration_id) do
    case Jason.decode(json) do
      {:ok, %{"tasks" => tasks}} ->
        result =
          Enum.map(tasks, fn
            [name, description] -> %BoltTask{name: name, description: description}
            [name] -> %BoltTask{name: name, description: nil}
          end)

        {:ok, result}

      {:ok, _unexpected} ->
        {:error, "unexpected bolt task show output shape"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_inventory(json, integration_id) do
    case Jason.decode(json) do
      {:ok, %{"targets" => targets}} ->
        nodes =
          Enum.map(targets, fn t ->
            name = t["name"] || t["uri"] || "unknown"
            config = t["config"] || %{}
            transport = config["transport"] || "ssh"
            transport_cfg = Map.get(config, transport, %{}) |> redact_secrets()

            %Node{
              name: name,
              display_name: name,
              attributes: %{
                "bolt_uri" => t["uri"],
                "groups" => t["groups"] || [],
                "transport" => transport,
                "transport_config" => transport_cfg,
                "vars" => t["vars"] || %{},
                "features" => t["features"] || [],
                "integration_id" => integration_id
              }
            }
          end)

        {:ok, nodes}

      {:ok, _unexpected} ->
        {:error, "unexpected bolt inventory show output shape"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp redact_secrets(transport_config) when is_map(transport_config) do
    Map.new(transport_config, fn {k, v} ->
      if k in @secret_fields, do: {k, "[REDACTED]"}, else: {k, v}
    end)
  end

  defp redact_secrets(other), do: other

  defp cli_module(config), do: Map.get(config, "cli_module", Vigil.Integrations.Bolt.CLI.Port)

  defp cli_opts(config) do
    base = Map.get(config, "cli_opts", [])
    wall = Map.get(config, "wall_clock_ms", @default_wall_clock_ms)
    idle = Map.get(config, "idle_ms", @default_idle_ms)
    Keyword.merge(base, wall_clock_ms: wall, idle_ms: idle)
  end

  defp ok_result(integration_id, data) do
    %Result{
      data: data,
      source: %Source{plugin_id: @plugin_id, integration_id: integration_id},
      fetched_at: DateTime.utc_now()
    }
  end

  defp no_instance_error(integration_id) do
    %Error{
      category: :configuration,
      message: "no running Bolt integration instance for #{inspect(integration_id)}",
      retriable?: false
    }
  end

  defp parse_error(reason) do
    %Error{
      category: :configuration,
      message: "could not parse bolt inventory output: #{inspect(reason)}",
      retriable?: false
    }
  end

  defp bolt_error(msg) do
    %Error{
      category: :transient_external,
      message: msg,
      retriable?: true,
      upstream_fault?: true
    }
  end

  defp transient_error(reason) do
    %Error{
      category: :transient_external,
      message: "bolt CLI invocation failed: #{inspect(reason)}",
      detail: %{reason: reason},
      retriable?: true,
      upstream_fault?: true
    }
  end
end

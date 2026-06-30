defmodule Vigil.Integrations.Ansible do
  @moduledoc """
  Ansible integration plugin (PRD §8.3, design §14).

  Capabilities: `:inventory`, `:facts`, `:execution`.

  Inventory acquisition delegates to `ansible-inventory --list` (ANS-INV-*),
  covering both static and dynamic inventory sources transparently. Facts are
  gathered via `ansible -m setup` (ANS-FACT-*). Execution supports ad-hoc
  commands and playbooks (ANS-401, ANS-402).

  Out of scope in this slice: VariableResolver, PlaybookDiscovery, VaultDetector,
  ProjectWatcher, Galaxy, streaming JSON callback parsing, journal contributions
  (#20 Journal infrastructure).
  """

  @behaviour Vigil.Plugin
  @behaviour Vigil.Plugin.Health
  @behaviour Vigil.Plugin.Inventory
  @behaviour Vigil.Plugin.Facts
  @behaviour Vigil.Plugin.Execution.Runner

  alias Vigil.Integrations.Ansible.{InventoryParser, Normalizer, Runner, Server}
  alias Vigil.Plugin.{Error, Permission, Result, Schema, Source}

  @plugin_id "ansible"
  @default_wall_clock_ms 3_600_000
  @default_idle_ms 300_000

  ## Vigil.Plugin contract

  @impl Vigil.Plugin
  def plugin_id, do: @plugin_id

  @impl Vigil.Plugin
  def display_name, do: "Ansible"

  @impl Vigil.Plugin
  def contract_version, do: Version.parse!("1.0.0")

  @impl Vigil.Plugin
  def capabilities, do: [:inventory, :facts, :execution]

  @impl Vigil.Plugin
  def config_schema do
    alias Vigil.Plugin.Schema.Field

    %Schema{
      fields: [
        %Field{
          name: "project_dir",
          type: :string,
          required: false,
          description: "Path to the Ansible project directory (ANS-104)."
        },
        %Field{
          name: "inventory",
          type: :string,
          required: false,
          description: "Inventory file, directory path, or dynamic inventory script."
        },
        %Field{
          name: "ansible_executable",
          type: :string,
          required: false,
          default: "ansible",
          description: "Path to the `ansible` binary."
        },
        %Field{
          name: "ansible_playbook_executable",
          type: :string,
          required: false,
          default: "ansible-playbook",
          description: "Path to the `ansible-playbook` binary."
        },
        %Field{
          name: "ansible_inventory_executable",
          type: :string,
          required: false,
          default: "ansible-inventory",
          description: "Path to the `ansible-inventory` binary."
        },
        %Field{
          name: "vault_password_file",
          type: :string,
          required: false,
          secret?: true,
          description: "Path to the Ansible Vault password file (ANS-503)."
        },
        %Field{
          name: "vault_password_command",
          type: :string,
          required: false,
          secret?: true,
          description: "Command that outputs the Vault password (ANS-503)."
        },
        %Field{
          name: "become_user",
          type: :string,
          required: false,
          description: "Default become user (ANS-504)."
        },
        %Field{
          name: "become_method",
          type: :string,
          required: false,
          description: "Default become method (ANS-504)."
        },
        %Field{
          name: "forks",
          type: :integer,
          required: false,
          default: 5,
          description: "Ansible --forks value and per-integration concurrency limit (ANS-805)."
        },
        %Field{
          name: "timeout.wall_clock",
          type: :integer,
          required: false,
          default: @default_wall_clock_ms,
          description: "Wall-clock timeout per CLI invocation in ms."
        },
        %Field{
          name: "timeout.idle",
          type: :integer,
          required: false,
          default: @default_idle_ms,
          description: "Idle timeout per CLI invocation in ms (streaming not yet implemented)."
        },
        %Field{
          name: "min_ansible_version",
          type: :string,
          required: false,
          default: "2.14.0",
          description: "Minimum acceptable Ansible version (ANS-604)."
        }
      ]
    }
  end

  @impl Vigil.Plugin
  def defaults do
    %{
      cache_ttl: %{inventory: 900_000, facts: 3_600_000},
      timeouts: %{inventory: 60_000},
      concurrency: 5
    }
  end

  @impl Vigil.Plugin
  def operational_permissions do
    [
      %Permission{
        kind: :filesystem,
        description: "Reads the Ansible project directory, inventory files, and host/group_vars."
      },
      %Permission{
        kind: :network,
        description: "Opens outbound SSH/WinRM connections to inventoried targets via Ansible."
      },
      %Permission{
        kind: :executable,
        description: "Invokes `ansible`, `ansible-inventory`, and `ansible-playbook` CLI binaries."
      },
      %Permission{
        kind: :credential,
        description: "Uses SSH keys, vault passwords, and become credentials from the Ansible project."
      }
    ]
  end

  @impl Vigil.Plugin
  def child_spec({integration_id, config}) do
    children = [{Server, {integration_id, config}}]

    %{
      id: {:ansible_supervisor, integration_id},
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
      cli = cli_module(config)
      cli_opts_kw = cli_opts(config)
      ansible_inventory_exe = Map.get(config, "ansible_inventory_executable", "ansible-inventory")
      inventory = Map.get(config, "inventory")
      wall_clock_ms = Map.get(config, "timeout.wall_clock", 60_000)

      args = ["--list"] ++ (if inventory, do: ["-i", inventory], else: [])

      case cli.run(ansible_inventory_exe, args, Keyword.merge(cli_opts_kw, wall_clock_ms: wall_clock_ms)) do
        {:ok, %{exit_status: 0, stdout: json}} ->
          case Jason.decode(json) do
            {:ok, inventory_map} ->
              case InventoryParser.parse(inventory_map, integration_id) do
                {:ok, nodes} -> {:ok, ok_result(integration_id, nodes)}
                {:error, reason} -> {:error, parse_error(reason)}
              end

            {:error, _} ->
              {:error, parse_error(:invalid_json)}
          end

        {:ok, %{exit_status: status, stdout: output}} ->
          {:error, cli_error("ansible-inventory exited #{status}: #{String.slice(output, 0, 200)}")}

        {:error, :not_found} ->
          {:error,
           %Error{
             category: :configuration,
             message: "ansible-inventory executable not found",
             retriable?: false
           }}

        {:error, :timeout} ->
          {:error, %Error{category: :transient_external, message: "ansible-inventory timed out", retriable?: true, upstream_fault?: true}}

        {:error, :malformed} ->
          {:error, parse_error(:malformed_json)}

        {:error, reason} ->
          {:error, transient_error(reason)}
      end
    else
      {:error, :not_found} -> {:error, no_instance_error(integration_id)}
    end
  end

  ## Vigil.Plugin.Facts

  @impl Vigil.Plugin.Facts
  def get_facts(integration_id, args) do
    node_name = args[:node] || args["node"]

    with {:ok, config} <- Server.get_config(integration_id) do
      cli = cli_module(config)
      cli_opts_kw = cli_opts(config)
      ansible_exe = Map.get(config, "ansible_executable", "ansible")
      inventory = Map.get(config, "inventory")
      wall_clock_ms = Map.get(config, "timeout.wall_clock", @default_wall_clock_ms)

      inv_args = if inventory, do: ["-i", inventory], else: []
      setup_args = [node_name || "all"] ++ inv_args ++ ["-m", "setup"]

      case cli.run(ansible_exe, setup_args, Keyword.merge(cli_opts_kw, wall_clock_ms: wall_clock_ms)) do
        {:ok, %{exit_status: 0, stdout: json}} ->
          case Jason.decode(json) do
            {:ok, result_map} ->
              facts = extract_facts(result_map, node_name)
              {:ok, ok_result(integration_id, facts)}

            {:error, _} ->
              {:error, parse_error(:invalid_json)}
          end

        {:ok, %{exit_status: status}} ->
          {:error, cli_error("ansible -m setup exited #{status}")}

        {:error, :not_found} ->
          {:error,
           %Error{
             category: :configuration,
             message: "ansible executable not found",
             retriable?: false
           }}

        {:error, :timeout} ->
          {:error, %Error{category: :transient_external, message: "ansible -m setup timed out", retriable?: true}}

        {:error, reason} ->
          {:error, transient_error(reason)}
      end
    else
      {:error, :not_found} -> {:error, no_instance_error(integration_id)}
    end
  end

  defp extract_facts(result_map, node_name) do
    host_result =
      cond do
        node_name && Map.has_key?(result_map, node_name) -> result_map[node_name]
        true -> result_map |> Map.values() |> List.first() || %{}
      end

    ansible_facts = host_result["ansible_facts"] || %{}
    Normalizer.normalize(ansible_facts)
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

  ## Vigil.Plugin.Health

  @impl Vigil.Plugin.Health
  def health_check(integration_id) do
    case Server.get_config(integration_id) do
      {:ok, config} ->
        cli = cli_module(config)
        cli_opts_kw = cli_opts(config)
        ansible_exe = Map.get(config, "ansible_executable", "ansible")

        case cli.run(ansible_exe, ["--version"], Keyword.merge(cli_opts_kw, wall_clock_ms: 10_000)) do
          {:ok, %{exit_status: 0}} -> {:ok, :healthy}
          {:error, :not_found} -> {:ok, :unhealthy}
          _ -> {:ok, :unhealthy}
        end

      {:error, :not_found} ->
        {:ok, :unhealthy}
    end
  end

  ## Internal

  defp cli_module(config), do: Map.get(config, "cli_module", Vigil.Integrations.Ansible.CLI.Port)

  defp cli_opts(config) do
    case Map.get(config, "cli_opts") do
      nil -> []
      opts when is_list(opts) -> opts
      _ -> []
    end
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
      message: "no running Ansible integration instance for #{inspect(integration_id)}",
      retriable?: false
    }
  end

  defp parse_error(reason) do
    %Error{
      category: :configuration,
      message: "could not parse ansible-inventory output: #{inspect(reason)}",
      retriable?: false
    }
  end

  defp cli_error(msg) do
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
      message: "Ansible CLI invocation failed: #{inspect(reason)}",
      detail: %{reason: reason},
      retriable?: true,
      upstream_fault?: true
    }
  end
end

defmodule Vigil.Integrations.SSH do
  @moduledoc """
  The SSH integration plugin (PRD §8 `SSH-*`, design §3) — the first real
  integration. It provides:

    * `:inventory` — hosts parsed from an OpenSSH client config file
      (`SSH-101`..`SSH-105`), and
    * `:facts` — a baseline set of system facts gathered over SSH
      (`SSH-201`, `SSH-202`).

  Command execution and streaming (`SSH-3xx`) are the next slice (#7). Fact
  caching with a TTL (`SSH-204`) rides on the shared integration cache (#12);
  the TTL is declared here but not yet enforced.

  The plugin is discovered via its OTP app `env: [vigil_plugin: __MODULE__]`
  (design §3.2.1). Each configured instance starts a small subtree
  (`Vigil.Integrations.SSH.Server` + `Vigil.Integrations.SSH.ConnectionPool`)
  under `Vigil.Integrations.Supervisor`; capability calls reach it through
  `Vigil.Plugin.Dispatcher`.
  """

  @behaviour Vigil.Plugin
  @behaviour Vigil.Plugin.Health
  @behaviour Vigil.Plugin.Inventory
  @behaviour Vigil.Plugin.Facts
  @behaviour Vigil.Plugin.Execution.Runner

  require Logger

  alias Vigil.Plugin.{Error, Node, Permission, Result, Schema, Source}

  alias Vigil.Integrations.SSH.{
    ConfigParser,
    ConnectionPool,
    FactParser,
    Runner,
    Server,
    Transport
  }

  @plugin_id "ssh"
  @default_config_file "~/.ssh/config"
  @default_connect_timeout_ms 10_000
  @default_facts_cache_ttl_ms 3_600_000

  # Baseline POSIX/Linux fact commands (SSH-202): no special tooling required.
  @fact_commands [
    {:os_release, "cat /etc/os-release"},
    {:uname, "uname -s -r -m"},
    {:ip_json, "ip -j addr"},
    {:meminfo, "cat /proc/meminfo"},
    {:nproc, "nproc"},
    {:hostname, "hostname"},
    {:uptime, "uptime -p"}
  ]

  ## Vigil.Plugin contract

  @impl Vigil.Plugin
  def plugin_id, do: @plugin_id

  @impl Vigil.Plugin
  def display_name, do: "SSH"

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
          name: "config_file",
          type: :string,
          required: false,
          default: @default_config_file,
          description: "Path to the OpenSSH client config file to read inventory from.",
          reload: :hot
        },
        %Field{
          name: "connect_timeout_ms",
          type: :integer,
          required: false,
          default: @default_connect_timeout_ms,
          description: "SSH connection timeout in milliseconds.",
          reload: :hot
        },
        %Field{
          name: "facts_cache_ttl_ms",
          type: :integer,
          required: false,
          default: @default_facts_cache_ttl_ms,
          description:
            "How long gathered facts stay fresh (enforced with the shared cache, #12).",
          reload: :hot
        },
        %Field{
          name: "skip_host_key_check",
          type: :boolean,
          required: false,
          default: false,
          description: "DEVELOPMENT ONLY — disables SSH host-key verification (SSH-404).",
          reload: :hot
        }
      ]
    }
  end

  @impl Vigil.Plugin
  def defaults do
    %{
      cache_ttl: %{inventory: 30_000, facts: @default_facts_cache_ttl_ms},
      timeouts: %{inventory: 5_000, facts: 30_000},
      concurrency: 5
    }
  end

  @impl Vigil.Plugin
  def operational_permissions do
    [
      %Permission{
        kind: :filesystem,
        description: "Reads the OpenSSH client config file and referenced identity files.",
        detail: %{default_path: @default_config_file}
      },
      %Permission{
        kind: :network,
        description: "Opens outbound SSH connections to inventoried hosts to gather facts."
      },
      %Permission{
        kind: :executable,
        description:
          "Runs read-only baseline commands on targets (uname, ip, cat /etc/os-release, …)."
      },
      %Permission{
        kind: :credential,
        description: "Uses SSH keys/agent from the host system's SSH configuration."
      }
    ]
  end

  @impl Vigil.Plugin
  def child_spec({integration_id, config}) do
    {transport, transport_opts} = Transport.from_config(config)

    children = [
      {Server, {integration_id, config}},
      {ConnectionPool,
       integration_id: integration_id,
       transport: transport,
       transport_opts: transport_opts,
       host_resolver: &connect_opts_for(integration_id, &1),
       name: pool_ref(integration_id)}
    ]

    %{
      id: {:ssh_supervisor, integration_id},
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
      case ConfigParser.parse_file(config_file(config)) do
        {:ok, nodes} ->
          {:ok, ok_result(integration_id, nodes)}

        # A missing config file is an empty inventory, not an error (ERR-* empty state).
        {:error, :enoent} ->
          {:ok, ok_result(integration_id, [])}

        {:error, reason} ->
          {:error, config_read_error(reason)}
      end
    else
      {:error, :not_found} -> {:error, no_instance_error(integration_id)}
    end
  end

  ## Vigil.Plugin.Facts

  @impl Vigil.Plugin.Facts
  def get_facts(integration_id, args) do
    host = args[:node] || args["node"]

    with {:ok, config} <- Server.get_config(integration_id),
         {:ok, host} <- require_host(host),
         {:ok, nodes} <- inventory(config),
         {:ok, node} <- find_targetable(nodes, host) do
      gather_facts(integration_id, config, node)
    else
      {:error, :not_found} -> {:error, no_instance_error(integration_id)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  ## Vigil.Plugin.Health

  @impl Vigil.Plugin.Health
  def health_check(integration_id) do
    case Server.get_config(integration_id) do
      {:ok, config} ->
        case ConfigParser.parse_file(config_file(config)) do
          {:ok, nodes} -> probe_hosts(integration_id, config, targetable(nodes))
          {:error, :enoent} -> {:ok, :degraded}
          {:error, _reason} -> {:ok, :unhealthy}
        end

      {:error, :not_found} ->
        {:ok, :unhealthy}
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

  ## Connection-option resolution (used by the pool and health probing)

  @doc false
  def connect_opts_for(integration_id, host) do
    with {:ok, config} <- Server.get_config(integration_id),
         {:ok, nodes} <- inventory(config) do
      node = Enum.find(nodes, &(&1.name == host))
      Keyword.merge(base_connect_opts(config), node_connect_opts(node))
    else
      _ -> []
    end
  end

  ## Internal

  defp gather_facts(integration_id, config, %Node{name: host}) do
    timeout = Map.get(config, "connect_timeout_ms", @default_connect_timeout_ms)

    results =
      Enum.map(@fact_commands, fn {key, command} ->
        {key, ConnectionPool.run(pool_ref(integration_id), host, command, timeout)}
      end)

    outputs =
      for {key, {:ok, %{exit_status: 0, stdout: out}}} <- results, into: %{}, do: {key, out}

    if outputs == %{} do
      {:error, facts_unreachable_error(host, results)}
    else
      {:ok, ok_result(integration_id, FactParser.merge(outputs))}
    end
  end

  defp probe_hosts(_integration_id, _config, []), do: {:ok, :healthy}

  defp probe_hosts(integration_id, config, hosts) do
    {transport, transport_opts} = Transport.from_config(config)

    reachable =
      Enum.count(hosts, fn %Node{name: host} ->
        opts = Keyword.merge(transport_opts, connect_opts_for(integration_id, host))

        case transport.connect(host, opts) do
          {:ok, conn} ->
            transport.close(conn)
            true

          _ ->
            false
        end
      end)

    status =
      cond do
        reachable == length(hosts) -> :healthy
        reachable == 0 -> :unhealthy
        true -> :degraded
      end

    {:ok, status}
  end

  defp inventory(config) do
    case ConfigParser.parse_file(config_file(config)) do
      {:ok, nodes} -> {:ok, nodes}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, config_read_error(reason)}
    end
  end

  defp require_host(nil),
    do: {:error, %Error{category: :user_input, message: "no node specified", retriable?: false}}

  defp require_host(host), do: {:ok, host}

  defp find_targetable(nodes, host) do
    case Enum.find(nodes, &(&1.name == host)) do
      %Node{targetable?: true} = node ->
        {:ok, node}

      %Node{targetable?: false} ->
        {:error,
         %Error{
           category: :user_input,
           message: "host #{inspect(host)} is a wildcard pattern and is not targetable (SSH-103)",
           retriable?: false
         }}

      nil ->
        {:error,
         %Error{
           category: :user_input,
           message: "host #{inspect(host)} is not in this integration's inventory",
           retriable?: false
         }}
    end
  end

  defp targetable(nodes), do: Enum.filter(nodes, & &1.targetable?)

  defp base_connect_opts(config) do
    [
      connect_timeout_ms: Map.get(config, "connect_timeout_ms", @default_connect_timeout_ms),
      skip_host_key_check: Map.get(config, "skip_host_key_check", false)
    ]
  end

  defp node_connect_opts(nil), do: []

  defp node_connect_opts(%Node{attributes: attrs}) do
    [port: attrs["port"], user: attrs["user"], user_dir: identity_dir(attrs["identity_file"])]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp identity_dir(nil), do: nil
  defp identity_dir(path), do: path |> Path.expand() |> Path.dirname()

  defp config_file(config), do: Map.get(config, "config_file", @default_config_file)

  defp pool_ref(integration_id),
    do: {:via, Registry, {Vigil.Plugin.Registry, {:ssh_pool, integration_id}}}

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
      message: "no running SSH integration instance for #{inspect(integration_id)}",
      retriable?: false
    }
  end

  defp config_read_error(reason) do
    %Error{
      category: :configuration,
      message: "could not read SSH config file: #{inspect(reason)}",
      detail: %{reason: reason},
      retriable?: false
    }
  end

  defp facts_unreachable_error(host, results) do
    reason =
      Enum.find_value(results, :unreachable, fn
        {_k, {:error, %Error{detail: %{reason: r}}}} -> r
        _ -> nil
      end)

    %Error{
      category: :transient_external,
      message: "could not gather facts from #{inspect(host)}: #{inspect(reason)}",
      detail: %{reason: reason},
      retriable?: true,
      upstream_fault?: true
    }
  end
end

defmodule Vigil.Integrations.Puppet do
  @moduledoc """
  The Puppet integration plugin — PuppetDB-backed inventory, facts, reports,
  events, and catalogs with mTLS auth, circuit breaker resilience, and
  server-side PQL filtering (PRD §7, design §11).

  Capabilities: `:inventory`, `:facts`, `:reports`, `:events`, `:hiera`.
  Out of scope: Puppetserver client, Hiera .pp static analysis (#18).
  """

  @behaviour Vigil.Plugin
  @behaviour Vigil.Plugin.Health
  @behaviour Vigil.Plugin.Inventory
  @behaviour Vigil.Plugin.Facts

  alias Vigil.Integrations.Puppet.{Catalog, CatalogDiff, CircuitBreaker, ConfigServer, Event, Hiera, PQL, Report, Resource}
  alias Vigil.Integrations.Puppet.PuppetDB.{Client, FinchHTTP}
  alias Vigil.Integrations.Puppet.Puppetserver
  alias Vigil.Plugin.{Error, Node, Permission, Result, Schema, Source}

  @plugin_id "puppet"

  ## Vigil.Plugin contract

  @impl Vigil.Plugin
  def plugin_id, do: @plugin_id

  @impl Vigil.Plugin
  def display_name, do: "Puppet"

  @impl Vigil.Plugin
  def contract_version, do: Version.parse!("1.0.0")

  @impl Vigil.Plugin
  def capabilities, do: [:inventory, :facts, :reports, :events, :hiera]

  @impl Vigil.Plugin
  def config_schema do
    alias Vigil.Plugin.Schema.Field

    %Schema{
      fields: [
        %Field{
          name: "puppetdb.url",
          type: :url,
          required: true,
          description: "Base URL of the PuppetDB API (e.g. https://puppetdb:8081)."
        },
        %Field{
          name: "puppetdb.client_cert",
          type: :string,
          required: false,
          secret?: true,
          description: "Path to client certificate PEM file for mTLS authentication (PUP-801)."
        },
        %Field{
          name: "puppetdb.client_key",
          type: :string,
          required: false,
          secret?: true,
          description: "Path to client private key PEM file for mTLS authentication."
        },
        %Field{
          name: "puppetdb.ca_cert",
          type: :string,
          required: false,
          description: "Path to CA certificate file for TLS verification (PUP-803)."
        },
        %Field{
          name: "control_repo.path",
          type: :string,
          required: false,
          description: "Absolute path to the local control-repo checkout (required for Hiera — PUP-301)."
        },
        %Field{
          name: "hiera.config_file",
          type: :string,
          required: false,
          default: "hiera.yaml",
          description: "Hiera config filename relative to the environment directory (PUP-301, default: hiera.yaml)."
        },
        %Field{
          name: "circuit_breaker.threshold",
          type: :integer,
          required: false,
          default: 5,
          description: "Consecutive failures before the circuit breaker opens (RES-002)."
        },
        %Field{
          name: "circuit_breaker.cooldown_ms",
          type: :integer,
          required: false,
          default: 30_000,
          description: "Cooldown period in ms after the breaker opens before a probe is allowed."
        },
        %Field{
          name: "puppetserver.url",
          type: :url,
          required: false,
          description: "Base URL of the Puppetserver API (e.g. https://puppetmaster:8140). Required for environment management and code deploy (PUP-501..508)."
        },
        %Field{
          name: "puppetserver.client_cert",
          type: :string,
          required: false,
          secret?: true,
          description: "Path to client certificate PEM file for Puppetserver mTLS."
        },
        %Field{
          name: "puppetserver.client_key",
          type: :string,
          required: false,
          secret?: true,
          description: "Path to client private key PEM file for Puppetserver mTLS."
        },
        %Field{
          name: "puppetserver.ca_cert",
          type: :string,
          required: false,
          description: "Path to CA certificate for Puppetserver TLS verification."
        },
        %Field{
          name: "code_deploy.method",
          type: :string,
          required: false,
          default: "r10k_webhook",
          description: "Code deploy method: r10k_webhook, code_manager, or remote_exec (PUP-504..507)."
        },
        %Field{
          name: "code_deploy.url",
          type: :url,
          required: false,
          description: "Webhook or Code Manager endpoint URL for code deployment."
        },
        %Field{
          name: "code_deploy.bearer_token",
          type: :string,
          required: false,
          secret?: true,
          description: "Bearer token for Code Manager authentication."
        },
        %Field{
          name: "code_deploy.exec_integration_id",
          type: :string,
          required: false,
          description: "Integration ID of an SSH/Bolt integration for remote_exec deploys (PUP-507)."
        }
      ]
    }
  end

  @impl Vigil.Plugin
  def defaults do
    %{
      cache_ttl: %{inventory: 900_000, facts: 1_800_000},
      timeouts: %{inventory: 30_000, facts: 30_000},
      concurrency: 10
    }
  end

  @impl Vigil.Plugin
  def operational_permissions do
    [
      %Permission{
        kind: :network,
        description: "Opens HTTPS/mTLS connections to PuppetDB for inventory and facts queries."
      },
      %Permission{
        kind: :credential,
        description: "Uses client certificates for mTLS authentication with PuppetDB (PUP-801)."
      }
    ]
  end

  @impl Vigil.Plugin
  def child_spec({integration_id, config}) do
    use_pdb_finch? = not Map.has_key?(config, "http_module")
    use_pss_finch? = not Map.has_key?(config, "puppetserver.http_module") and Map.has_key?(config, "puppetserver.url")

    finch_children =
      (if use_pdb_finch?, do: [FinchHTTP.child_spec(integration_id, config)], else: []) ++
      (if use_pss_finch?, do: [Puppetserver.FinchHTTP.child_spec(integration_id, config)], else: [])

    children =
      [
        {ConfigServer, {integration_id, config}},
        {CircuitBreaker, {integration_id, config}}
      ] ++ finch_children

    %{
      id: {:puppet_supervisor, integration_id},
      start:
        {Supervisor, :start_link,
         [children, [strategy: :one_for_one, max_restarts: 10, max_seconds: 60]]},
      type: :supervisor,
      restart: :permanent
    }
  end

  ## Vigil.Plugin.Inventory

  @impl Vigil.Plugin.Inventory
  def list_nodes(integration_id, opts) do
    filter = opts[:filter] || opts["filter"] || %{}
    pql = PQL.nodes_query(filter)

    case Client.query(integration_id, pql) do
      {:ok, raw_nodes} ->
        nodes = Enum.map(raw_nodes, &normalize_node(&1, integration_id))
        {:ok, ok_result(integration_id, nodes)}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, transient_error(reason)}
    end
  end

  ## Vigil.Plugin.Facts

  @impl Vigil.Plugin.Facts
  def get_facts(integration_id, args) do
    certname = args[:node] || args["node"]

    if is_nil(certname) do
      {:error,
       %Error{
         category: :user_input,
         message: "no node specified — pass args[:node] with the PuppetDB certname",
         retriable?: false
       }}
    else
      pql = PQL.facts_query(certname)

      case Client.query(integration_id, pql) do
        {:ok, raw_facts} ->
          facts = normalize_facts(raw_facts)
          {:ok, ok_result(integration_id, facts)}

        {:error, %Error{} = error} ->
          {:error, error}

        {:error, reason} ->
          {:error, transient_error(reason)}
      end
    end
  end

  ## Reports (PUP-701..713)

  def get_reports(integration_id, opts) do
    filter = if is_map(opts), do: opts, else: %{}
    pql = PQL.reports_query(filter)

    case Client.query(integration_id, pql) do
      {:ok, raw} ->
        {:ok, ok_result(integration_id, Enum.map(raw, &normalize_report/1))}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, transient_error(reason)}
    end
  end

  ## Events (PUP-601..607)

  def fetch_events(integration_id, certname, opts) do
    time_range = Keyword.fetch!(opts, :time_range)
    pql = PQL.events_query(certname, time_range)

    case Client.query(integration_id, pql) do
      {:ok, raw} ->
        {:ok, ok_result(integration_id, Enum.map(raw, &normalize_event/1))}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, transient_error(reason)}
    end
  end

  ## Catalogs (PUP-401..403)

  def get_catalog(integration_id, certname, _opts) do
    pql = PQL.catalog_query(certname)

    case Client.query(integration_id, pql) do
      {:ok, [raw | _]} ->
        {:ok, ok_result(integration_id, normalize_catalog(raw))}

      {:ok, []} ->
        {:error, %Error{category: :not_found, message: "no catalog found for #{certname}", retriable?: false}}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, transient_error(reason)}
    end
  end

  ## Catalog diff (PUP-404..405)

  def compute_diff(%Catalog{} = cat_a, %Catalog{} = cat_b) do
    map_a = Map.new(cat_a.resources, fn r -> {{r.type, r.title}, r} end)
    map_b = Map.new(cat_b.resources, fn r -> {{r.type, r.title}, r} end)

    keys_a = MapSet.new(Map.keys(map_a))
    keys_b = MapSet.new(Map.keys(map_b))

    only_in_a = for k <- MapSet.difference(keys_a, keys_b), do: map_a[k]
    only_in_b = for k <- MapSet.difference(keys_b, keys_a), do: map_b[k]

    {changed, identical_count} =
      MapSet.intersection(keys_a, keys_b)
      |> Enum.reduce({[], 0}, fn key, {changed_acc, count} ->
        param_diffs = diff_params(map_a[key].parameters, map_b[key].parameters)

        if map_size(param_diffs) == 0 do
          {changed_acc, count + 1}
        else
          {[%{resource: map_a[key], param_diffs: param_diffs} | changed_acc], count}
        end
      end)

    %CatalogDiff{
      only_in_a: only_in_a,
      only_in_b: only_in_b,
      changed: changed,
      identical_count: identical_count
    }
  end

  def diff_catalogs(integration_id, node, _env_a, _env_b, opts) do
    with {:ok, %{data: cat_a}} <- get_catalog(integration_id, node, opts),
         {:ok, %{data: cat_b}} <- get_catalog(integration_id, node, opts) do
      {:ok, compute_diff(cat_a, cat_b)}
    end
  end

  ## Hiera (PUP-301..314)

  def browse_hierarchy(integration_id, environment, _opts \\ []) do
    case Hiera.Reader.read_hierarchy(integration_id, environment) do
      {:ok, levels} -> {:ok, ok_result(integration_id, levels)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def resolve_key(integration_id, environment, key, node_context, opts \\ []) do
    case Hiera.Reader.resolve_key(integration_id, environment, key, node_context, opts) do
      {:ok, resolution} -> {:ok, ok_result(integration_id, resolution)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  ## Environments (PUP-501..503)

  def list_environments(integration_id) do
    case Puppetserver.Client.list_environments(integration_id) do
      {:ok, envs} -> {:ok, ok_result(integration_id, envs)}
      {:error, %Error{} = e} -> {:error, e}
      {:error, reason} -> {:error, transient_pss_error(reason)}
    end
  end

  def flush_environment_cache(integration_id, environment \\ nil) do
    case Puppetserver.Client.flush_environment_cache(integration_id, environment) do
      {:ok, :flushed} -> {:ok, :flushed}
      {:error, %Error{} = e} -> {:error, e}
      {:error, reason} -> {:error, transient_pss_error(reason)}
    end
  end

  ## Code deployment (PUP-504..507)

  @doc "Deploy a single named environment. Requires `puppet:environment:deploy` (PUP-504(a))."
  def deploy_environment(integration_id, environment, principal)
      when is_binary(environment) and environment != "" do
    do_deploy(integration_id, {:single, environment}, principal)
  end

  @doc "Deploy all environments. Same RBAC permission as deploy_environment/3 (PUP-504(b))."
  def deploy_all_environments(integration_id, principal) do
    do_deploy(integration_id, :all, principal)
  end

  defp do_deploy(integration_id, scope, _principal) do
    with {:ok, config} <- ConfigServer.get_config(integration_id) do
      method = parse_deploy_method(Map.get(config, "code_deploy.method", "r10k_webhook"))

      case method do
        :r10k_webhook -> Puppetserver.Client.webhook_deploy(integration_id, scope)
        :code_manager -> Puppetserver.Client.code_manager_deploy(integration_id, scope)
        :remote_exec -> remote_exec_deploy(integration_id, scope, config)
      end
    else
      {:error, :not_found} ->
        {:error, %Error{category: :configuration, message: "no running Puppet integration found", retriable?: false}}
    end
  end

  defp parse_deploy_method("r10k_webhook"), do: :r10k_webhook
  defp parse_deploy_method("code_manager"), do: :code_manager
  defp parse_deploy_method("remote_exec"), do: :remote_exec
  defp parse_deploy_method(atom) when is_atom(atom), do: atom

  defp remote_exec_deploy(integration_id, scope, config) do
    exec_int_id = Map.get(config, "code_deploy.exec_integration_id")

    if is_nil(exec_int_id) do
      {:error, %Error{category: :config_error, message: "code_deploy.exec_integration_id is not configured", retriable?: false}}
    else
      command = r10k_command(scope)
      dispatcher = Map.get(config, "dispatcher_module", Vigil.Plugin.Dispatcher)

      case dispatcher.call(integration_id, exec_int_id, :run_command, %{command: command}) do
        {:ok, _} = ok -> ok
        {:error, reason} -> {:error, transient_pss_error(reason)}
      end
    end
  end

  defp r10k_command(:all), do: "r10k deploy environment --all"
  defp r10k_command({:single, env}), do: "r10k deploy environment #{env}"

  ## Vigil.Plugin.Health

  @impl Vigil.Plugin.Health
  def health_check(integration_id) do
    pql = PQL.probe_query()

    case Client.query(integration_id, pql) do
      {:ok, _} -> {:ok, :healthy}
      {:error, _} -> {:ok, :unhealthy}
    end
  end

  ## Internal

  defp diff_params(params_a, params_b) do
    all_keys = MapSet.new(Map.keys(params_a) ++ Map.keys(params_b))

    Enum.reduce(all_keys, %{}, fn key, acc ->
      val_a = Map.get(params_a, key)
      val_b = Map.get(params_b, key)
      if val_a == val_b, do: acc, else: Map.put(acc, key, %{in_a: val_a, in_b: val_b})
    end)
  end

  defp normalize_catalog(raw) do
    %Catalog{
      certname: raw["certname"],
      environment: raw["environment"],
      version: raw["version"],
      resources: Enum.map(raw["resources"] || [], &normalize_resource/1),
      edges: raw["edges"] || []
    }
  end

  defp normalize_resource(raw) do
    %Resource{
      type: raw["type"],
      title: raw["title"],
      parameters: raw["parameters"] || %{},
      tags: raw["tags"] || [],
      file: raw["file"],
      line: raw["line"],
      exported: raw["exported"] || false
    }
  end

  defp normalize_event(raw) do
    report_id = raw["report"]
    resource_type = raw["resource_type"]
    resource_title = raw["resource_title"]

    %Event{
      source_event_id: "#{report_id}:#{resource_type}[#{resource_title}]",
      occurred_at: raw["timestamp"],
      entry_type: "configuration_change",
      summary: "#{resource_type}[#{resource_title}]: #{raw["message"]}",
      severity: if(raw["status"] == "failure", do: :error, else: :informational),
      detail: %{
        resource_type: resource_type,
        resource_title: resource_title,
        old_value: raw["old_value"],
        new_value: raw["new_value"],
        file: raw["file"],
        line: raw["line"],
        containment_path: raw["containment_path"]
      },
      group_key: report_id,
      references: %{report_id: report_id}
    }
  end

  defp normalize_report(raw) do
    %Report{
      certname: raw["certname"],
      hash: raw["hash"],
      status: raw["status"],
      start_time: raw["start_time"],
      end_time: raw["end_time"],
      run_duration: raw["run_duration"],
      num_changes: raw["num_changes"],
      num_failures: raw["num_failures"],
      num_corrective_changes: raw["num_corrective_changes"],
      num_skips: raw["num_skips"],
      num_noops: raw["num_noops"],
      noop: raw["noop"],
      environment: raw["environment"],
      catalog_uuid: raw["catalog_uuid"],
      code_id: raw["code_id"]
    }
  end

  defp normalize_node(raw, integration_id) do
    certname = raw["certname"]
    deactivated = raw["deactivated"]
    expired = raw["expired"]

    status =
      cond do
        not is_nil(deactivated) -> :deactivated
        not is_nil(expired) -> :deactivated
        true -> :active
      end

    %Node{
      name: certname,
      display_name: certname,
      attributes: %{
        "certname" => certname,
        "fqdn" => certname,
        "hostname" => hostname_from_certname(certname),
        "status" => to_string(status),
        "latest_report_status" => raw["latest_report_status"],
        "integration_id" => integration_id
      }
    }
  end

  defp normalize_facts(raw_facts) do
    Map.new(raw_facts, fn %{"name" => name, "value" => value} -> {name, value} end)
  end

  defp hostname_from_certname(certname) when is_binary(certname) do
    certname |> String.split(".") |> List.first()
  end

  defp hostname_from_certname(_), do: nil

  defp ok_result(integration_id, data) do
    %Result{
      data: data,
      source: %Source{plugin_id: @plugin_id, integration_id: integration_id},
      fetched_at: DateTime.utc_now()
    }
  end

  defp transient_error(reason) do
    %Error{
      category: :transient_external,
      message: "PuppetDB query failed: #{inspect(reason)}",
      detail: %{reason: reason},
      retriable?: true,
      upstream_fault?: true
    }
  end

  defp transient_pss_error(reason) do
    %Error{
      category: :transient_external,
      message: "Puppetserver request failed: #{inspect(reason)}",
      detail: %{reason: reason},
      retriable?: true,
      upstream_fault?: true
    }
  end
end

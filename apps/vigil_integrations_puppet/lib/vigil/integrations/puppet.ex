defmodule Vigil.Integrations.Puppet do
  @moduledoc """
  The Puppet integration plugin — issue #10 slice: PuppetDB-backed inventory +
  facts, with mTLS auth, circuit breaker resilience, and server-side PQL
  filtering (PRD §7, design §11).

  Capabilities in this slice: `:inventory`, `:facts`.
  Out of scope here: Puppetserver client, Hiera, reports, events, catalogs
  (#16, #17, #18).
  """

  @behaviour Vigil.Plugin
  @behaviour Vigil.Plugin.Health
  @behaviour Vigil.Plugin.Inventory
  @behaviour Vigil.Plugin.Facts

  alias Vigil.Integrations.Puppet.{CircuitBreaker, ConfigServer, PQL}
  alias Vigil.Integrations.Puppet.PuppetDB.{Client, FinchHTTP}
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
  def capabilities, do: [:inventory, :facts]

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
    use_finch? = not Map.has_key?(config, "http_module")

    finch_children =
      if use_finch?,
        do: [FinchHTTP.child_spec(integration_id, config)],
        else: []

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
end

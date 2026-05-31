defmodule Vigil.Plugin.NoOp do
  @moduledoc """
  Reference no-op plugin (PLUG-702, design §3.7). Declares capabilities and
  returns well-formed stub responses without doing any real work. Used to smoke
  test the platform contract itself and to run the conformance suite against a
  known-good implementation.
  """

  @behaviour Vigil.Plugin
  @behaviour Vigil.Plugin.Health
  @behaviour Vigil.Plugin.Inventory
  @behaviour Vigil.Plugin.Facts
  @behaviour Vigil.Plugin.Execution.Runner

  alias Vigil.Plugin.{Result, Source}

  @plugin_id "noop"

  @impl Vigil.Plugin
  def plugin_id, do: @plugin_id

  @impl Vigil.Plugin
  def display_name, do: "No-op (reference)"

  @impl Vigil.Plugin
  def contract_version, do: Version.parse!("1.0.0")

  @impl Vigil.Plugin
  def capabilities, do: [:inventory, :execution]

  @impl Vigil.Plugin
  def config_schema do
    alias Vigil.Plugin.Schema.Field

    %Vigil.Plugin.Schema{
      fields: [
        %Field{
          name: "check_interval_ms",
          type: :integer,
          required: false,
          default: 30_000,
          description: "Health-check interval in milliseconds.",
          reload: :hot
        },
        %Field{
          name: "endpoint_url",
          type: :url,
          required: false,
          description: "Simulated endpoint URL (triggers restart on change).",
          reload: :restart
        }
      ]
    }
  end

  @impl Vigil.Plugin
  def defaults do
    %{
      cache_ttl: %{inventory: 30_000},
      timeouts: %{inventory: 5_000, execution: 60_000},
      concurrency: 1
    }
  end

  @impl Vigil.Plugin
  def operational_permissions, do: []

  @impl Vigil.Plugin
  def child_spec({integration_id, config}) do
    children = [
      {Vigil.Plugin.NoOp.Server, {integration_id, config}},
      {Vigil.Plugin.NoOp.ConfigServer, {integration_id, config}}
    ]

    %{
      id: {:noop_supervisor, integration_id},
      start:
        {Supervisor, :start_link,
         [children, [strategy: :one_for_one, max_restarts: 10, max_seconds: 60]]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @impl Vigil.Plugin.Health
  def health_check(_integration_id), do: {:ok, :healthy}

  @impl Vigil.Plugin.Execution.Runner
  def start(_integration_id, _artifact, _targets, _opts), do: {:ok, make_ref()}

  @impl Vigil.Plugin.Execution.Runner
  def abort(_runner_ref), do: :ok

  @impl Vigil.Plugin.Inventory
  def list_nodes(integration_id, _opts) do
    {:ok,
     %Result{
       data: [],
       source: %Source{plugin_id: @plugin_id, integration_id: integration_id},
       fetched_at: DateTime.utc_now()
     }}
  end

  # Implements the Facts behaviour (so it can stand in as a dispatch target for
  # the FactsContract) without declaring the `:facts` capability itself.
  @impl Vigil.Plugin.Facts
  def get_facts(integration_id, _args) do
    {:ok,
     %Result{
       data: %{},
       source: %Source{plugin_id: @plugin_id, integration_id: integration_id},
       fetched_at: DateTime.utc_now()
     }}
  end
end

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
  def config_schema, do: %Vigil.Plugin.Schema{fields: []}

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
    %{
      id: {:noop, integration_id},
      start: {Vigil.Plugin.NoOp.Server, :start_link, [{integration_id, config}]},
      type: :worker,
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
end

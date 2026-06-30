defmodule VigilWeb.PerfPlugin do
  @moduledoc """
  Configurable inventory plugin for :perf-tagged tests.

  Serves whatever node list the test seeds via child_spec/1. Registers itself
  in Vigil.Plugin.Registry under both the standard {:integration, id} key
  (so the Dispatcher routes to it) and a {:perf_server, id} key (so
  list_nodes/2 can look up the node list from the GenServer).

  Usage:

      start_supervised!(PerfPlugin.child_spec({integration_id, nodes: nodes}))
  """

  @behaviour Vigil.Plugin
  @behaviour Vigil.Plugin.Health
  @behaviour Vigil.Plugin.Inventory

  alias Vigil.Plugin.{Result, Schema, Source}

  @plugin_id "perf_test"

  @impl Vigil.Plugin
  def plugin_id, do: @plugin_id
  @impl Vigil.Plugin
  def display_name, do: "Perf Test Plugin"
  @impl Vigil.Plugin
  def contract_version, do: Version.parse!("1.0.0")
  @impl Vigil.Plugin
  def capabilities, do: [:inventory]
  @impl Vigil.Plugin
  def config_schema, do: %Schema{fields: []}
  @impl Vigil.Plugin
  def defaults, do: %{cache_ttl: %{}, timeouts: %{}, concurrency: 1}
  @impl Vigil.Plugin
  def operational_permissions, do: []

  @impl Vigil.Plugin
  def child_spec({integration_id, nodes: nodes}) do
    %{
      id: {:perf_test, integration_id},
      start: {VigilWeb.PerfPlugin.Server, :start_link, [{integration_id, nodes}]},
      type: :worker,
      restart: :temporary
    }
  end

  @impl Vigil.Plugin.Health
  def health_check(_integration_id), do: {:ok, :healthy}

  @impl Vigil.Plugin.Inventory
  def list_nodes(integration_id, _opts) do
    nodes =
      case Registry.lookup(Vigil.Plugin.Registry, {:perf_server, integration_id}) do
        [{pid, _}] -> GenServer.call(pid, :get_nodes)
        [] -> []
      end

    {:ok,
     %Result{
       data: nodes,
       source: %Source{plugin_id: @plugin_id, integration_id: integration_id},
       fetched_at: DateTime.utc_now()
     }}
  end
end

defmodule VigilWeb.PerfPlugin.Server do
  @moduledoc false
  use GenServer

  def start_link({integration_id, nodes}),
    do: GenServer.start_link(__MODULE__, {integration_id, nodes})

  @impl true
  def init({integration_id, nodes}) do
    {:ok, _} =
      Registry.register(
        Vigil.Plugin.Registry,
        {:integration, integration_id},
        VigilWeb.PerfPlugin
      )

    {:ok, _} =
      Registry.register(
        Vigil.Plugin.Registry,
        {:perf_server, integration_id},
        nil
      )

    {:ok, %{nodes: nodes, call_count: 0}}
  end

  @impl true
  def handle_call(:get_nodes, _from, state),
    do: {:reply, state.nodes, %{state | call_count: state.call_count + 1}}

  def handle_call(:get_call_count, _from, state),
    do: {:reply, state.call_count, state}
end

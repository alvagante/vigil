defmodule VigilWeb.InventoryTestPlugin do
  @moduledoc """
  Minimal in-test plugin exercising the inventory LiveViews without coupling
  `vigil_web` to any concrete integration app. It returns canned inventory and
  facts so `InventoryLive`/`NodeDetailLive` can be tested against the generic
  plugin contract.
  """

  @behaviour Vigil.Plugin
  @behaviour Vigil.Plugin.Health
  @behaviour Vigil.Plugin.Inventory
  @behaviour Vigil.Plugin.Facts

  alias Vigil.Plugin.{Error, Node, Result, Schema, Source}

  @plugin_id "web_test"

  @impl Vigil.Plugin
  def plugin_id, do: @plugin_id
  @impl Vigil.Plugin
  def display_name, do: "Web Test"
  @impl Vigil.Plugin
  def contract_version, do: Version.parse!("1.0.0")
  @impl Vigil.Plugin
  def capabilities, do: [:inventory, :facts]
  @impl Vigil.Plugin
  def config_schema, do: %Schema{fields: []}
  @impl Vigil.Plugin
  def defaults, do: %{cache_ttl: %{}, timeouts: %{}, concurrency: 1}
  @impl Vigil.Plugin
  def operational_permissions, do: []

  @impl Vigil.Plugin
  def child_spec({integration_id, config}) do
    %{
      id: {:web_test, integration_id},
      start: {__MODULE__.Server, :start_link, [{integration_id, config}]},
      type: :worker,
      restart: :temporary
    }
  end

  @impl Vigil.Plugin.Health
  def health_check(_integration_id), do: {:ok, :healthy}

  @impl Vigil.Plugin.Inventory
  def list_nodes(integration_id, _opts) do
    {:ok,
     %Result{
       data: [
         %Node{
           name: "alpha",
           attributes: %{"hostname" => "10.0.0.1", "port" => 22},
           targetable?: true
         },
         %Node{name: "*.wild", attributes: %{}, targetable?: false}
       ],
       source: source(integration_id),
       fetched_at: DateTime.utc_now()
     }}
  end

  @impl Vigil.Plugin.Facts
  def get_facts(integration_id, %{"node" => "alpha"}) do
    {:ok,
     %Result{
       data: %{"os.distro" => "ubuntu", "cpu.count" => 4},
       source: source(integration_id),
       fetched_at: DateTime.utc_now()
     }}
  end

  def get_facts(_integration_id, _args) do
    {:error, %Error{category: :user_input, message: "unknown node", retriable?: false}}
  end

  defp source(integration_id),
    do: %Source{plugin_id: @plugin_id, integration_id: integration_id}

  defmodule Server do
    @moduledoc false
    use GenServer

    def start_link({integration_id, _config}),
      do: GenServer.start_link(__MODULE__, integration_id)

    @impl true
    def init(integration_id) do
      {:ok, _} =
        Registry.register(
          Vigil.Plugin.Registry,
          {:integration, integration_id},
          VigilWeb.InventoryTestPlugin
        )

      {:ok, integration_id}
    end
  end
end

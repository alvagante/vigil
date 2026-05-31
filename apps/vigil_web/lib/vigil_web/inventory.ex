defmodule VigilWeb.Inventory do
  @moduledoc """
  Read-path that aggregates inventory and facts across enabled integrations for
  the inventory LiveViews (design §9.6.1/§9.6.2, `INV-201`).

  The Dispatcher fan-out lives here in `vigil_web` rather than `vigil_core`
  because core must not call down into `vigil_plugin` (design §2 dependency
  direction). This is the minimal synchronous fan-out: one source per node, no
  cache, no progressive per-source streaming. The shared cache (#12), unified
  cross-source linking (#22), and 10k-node streaming arrive later; this honours
  the same `Vigil.Core.Facts` row shape so those slices can replace the
  fetch strategy without changing the rendering contract.

  Node IDs are opaque composites of `integration_id` + the plugin's node name,
  URL-safe Base64 encoded. `#22`'s persisted node identities supersede this.
  """

  alias Vigil.Core.{Facts, IntegrationConfig}
  alias Vigil.Plugin.{Catalog, Dispatcher, Result}

  @sep "\n"

  @typedoc "A rendered inventory row with source attribution."
  @type entry :: %{
          id: String.t(),
          name: String.t(),
          attributes: map(),
          targetable?: boolean(),
          source: Facts.Row.source()
        }

  @doc """
  Aggregate inventory across all enabled inventory-capable integrations.
  Returns the flattened node entries plus a per-source status summary (so the
  UI can show which sources are OK and which are down — `INV-201`, `ERR-*`).
  """
  @spec list_inventory() :: %{nodes: [entry()], sources: [map()]}
  def list_inventory do
    results =
      enabled_sources(:inventory)
      |> Enum.map(fn integ ->
        case Dispatcher.call(integ.id, :inventory, :list_nodes, %{}) do
          {:ok, %Result{data: nodes, fetched_at: at}} ->
            %{integration: integ, status: :ok, fetched_at: at, nodes: entries(integ, nodes, at)}

          {:error, error} ->
            %{integration: integ, status: {:error, error}, fetched_at: nil, nodes: []}
        end
      end)

    %{
      nodes: Enum.flat_map(results, & &1.nodes),
      sources: Enum.map(results, &source_summary/1)
    }
  end

  @doc "Resolve a node entry by its composite id, or `{:error, :not_found}`."
  @spec get_node(String.t()) :: {:ok, entry()} | {:error, :not_found}
  def get_node(node_id) do
    with {:ok, integration_id, _name} <- decode(node_id),
         {:ok, integ} <- fetch_integration(integration_id),
         {:ok, %Result{data: nodes, fetched_at: at}} <-
           Dispatcher.call(integration_id, :inventory, :list_nodes, %{}),
         %{} = entry <- Enum.find(entries(integ, nodes, at), &(&1.id == node_id)) do
      {:ok, entry}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Fetch the facts table rows for a node. Returns `{:ok, rows}`, `{:error, error}`
  when the source reports a structured failure (unreachable host, etc.), or
  `{:error, :unsupported}` when no facts-capable source backs the node.
  """
  @spec facts_for(String.t()) :: {:ok, [Facts.Row.t()]} | {:error, term()}
  def facts_for(node_id) do
    with {:ok, integration_id, name} <- decode(node_id),
         {:ok, integ} <- fetch_integration(integration_id),
         true <- supports?(integ, :facts) or {:error, :unsupported},
         {:ok, %Result{data: facts, fetched_at: at}} <-
           Dispatcher.call(integration_id, :facts, :get_facts, %{"node" => name}) do
      {:ok, Facts.rows_from_source(facts, source_meta(integ, at))}
    end
  end

  @doc "Encode a composite node id from an integration id and plugin node name."
  @spec encode_id(String.t(), String.t()) :: String.t()
  def encode_id(integration_id, name) do
    Base.url_encode64(integration_id <> @sep <> name, padding: false)
  end

  ## Internal

  defp entries(integ, nodes, fetched_at) do
    source = source_meta(integ, fetched_at)

    Enum.map(nodes, fn node ->
      %{
        id: encode_id(integ.id, node.name),
        name: node.name,
        attributes: node.attributes,
        targetable?: node.targetable?,
        source: source
      }
    end)
  end

  defp source_meta(integ, fetched_at) do
    %{
      plugin_id: integ.plugin_id,
      integration_id: integ.id,
      integration_name: integ.name,
      gathered_at: fetched_at
    }
  end

  defp source_summary(%{integration: integ, status: status, nodes: nodes}) do
    %{
      integration_id: integ.id,
      integration_name: integ.name,
      plugin_id: integ.plugin_id,
      status: status,
      count: length(nodes)
    }
  end

  defp enabled_sources(capability) do
    IntegrationConfig.list_enabled()
    |> Enum.filter(&supports?(&1, capability))
  end

  defp supports?(integ, capability) do
    case Catalog.lookup(integ.plugin_id) do
      {:ok, module} -> capability in module.capabilities()
      {:error, :not_found} -> false
    end
  end

  defp fetch_integration(integration_id) do
    {:ok, IntegrationConfig.get!(integration_id)}
  rescue
    # Missing row, or a hand-crafted id whose decoded prefix isn't a valid UUID.
    _e in [Ecto.NoResultsError, Ecto.Query.CastError] -> {:error, :not_found}
  end

  defp decode(id) do
    with {:ok, raw} <- Base.url_decode64(id, padding: false),
         [integration_id, name] <- String.split(raw, @sep, parts: 2) do
      {:ok, integration_id, name}
    else
      _ -> {:error, :not_found}
    end
  end
end

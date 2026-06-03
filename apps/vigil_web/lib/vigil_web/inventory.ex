defmodule VigilWeb.Inventory do
  @moduledoc """
  Read-path that aggregates inventory and facts across enabled integrations for
  the inventory LiveViews (design §9.6.1/§9.6.2, `INV-201`).

  The Dispatcher fan-out lives here in `vigil_web` rather than `vigil_core`
  because core must not call down into `vigil_plugin` (design §2 dependency
  direction). Results are served from the shared integration cache (ADR-0006);
  RBAC target-scope filtering via `filter_targets/3` is applied before any data
  leaves this module — unfiltered cache entries never cross the application
  boundary.

  Pagination is a post-filter operation (ADR-0006): the cursor applies to the
  principal-filtered node list, not the raw integration result.

  Node IDs are opaque composites of `integration_id` + the plugin's node name,
  URL-safe Base64 encoded. `#22`'s persisted node identities supersede this.
  """

  alias Vigil.Core.{Facts, IntegrationConfig, RBAC}
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
  Aggregate inventory across all enabled inventory-capable integrations, apply
  RBAC target-scope filtering for `principal`, and paginate.

  Options:
  - `page_size: integer` — max nodes to return per page (default: all)
  - `cursor: string` — ID of the last node seen (nil = start of list)

  Returns `%{nodes: page, sources: source_summaries, next_cursor: id | nil, total_filtered: integer}`.
  """
  @spec list_inventory(term(), keyword()) :: %{
          nodes: [entry()],
          sources: [map()],
          next_cursor: String.t() | nil,
          total_filtered: non_neg_integer()
        }
  def list_inventory(principal, opts \\ []) do
    page_size = Keyword.get(opts, :page_size)
    cursor = Keyword.get(opts, :cursor)

    raw_results = fan_out(:inventory)

    filtered_nodes =
      raw_results
      |> Enum.filter(&match?(%{status: :ok}, &1))
      |> Enum.flat_map(fn %{integration: integ, nodes: nodes} ->
        RBAC.filter_targets(nodes, principal, integ.id)
      end)

    total_filtered = length(filtered_nodes)
    {page, next_cursor} = paginate(filtered_nodes, cursor, page_size)

    %{
      nodes: page,
      sources: Enum.map(raw_results, &source_summary/1),
      next_cursor: next_cursor,
      total_filtered: total_filtered
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

  defp fan_out(capability) do
    enabled_sources(capability)
    |> Enum.map(fn integ ->
      case Dispatcher.call(integ.id, capability, :list_nodes, %{}) do
        {:ok, %Result{data: nodes, fetched_at: at}} ->
          %{integration: integ, status: :ok, fetched_at: at, nodes: entries(integ, nodes, at)}

        {:error, error} ->
          %{integration: integ, status: {:error, error}, fetched_at: nil, nodes: []}
      end
    end)
  end

  defp paginate(nodes, cursor, nil), do: {after_cursor(nodes, cursor), nil}

  defp paginate(nodes, cursor, page_size) do
    tail = after_cursor(nodes, cursor)
    page = Enum.take(tail, page_size)
    next_cursor = if length(tail) > page_size, do: List.last(page).id, else: nil
    {page, next_cursor}
  end

  defp after_cursor(nodes, nil), do: nodes

  defp after_cursor(nodes, cursor) do
    nodes
    |> Enum.drop_while(&(&1.id != cursor))
    |> Enum.drop(1)
  end

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

defmodule VigilWeb.NodeDetailLive do
  @moduledoc """
  Per-node detail page (design §9.6.2) — issue #6.
  Routes: /inventory/node/:id and /inventory/node/:id/:tab

  Shows a node's header (name, source attribution, targetability) and a tabbed
  body. For #6 the only tab is **Facts**, populated by the node's facts-capable
  source and rendered as the source-badged table from design §9.7.1. The facts
  section loads asynchronously so a slow or unreachable source does not block the
  page (design §9.5, `FLOW-002`); its failure is contained to the tab (`ERR-*`).

  The full canonical tab set (Configuration, Events, Run History, …) and
  supplementary plugin tabs arrive with the capabilities that back them.
  """

  use VigilWeb, :live_view

  alias VigilWeb.Inventory

  @impl true
  def mount(%{"id" => id} = _params, _session, socket) do
    case Inventory.get_node(id) do
      {:ok, node} ->
        {:ok,
         socket
         |> assign(:page_title, node.name)
         |> assign(:node, node)
         |> assign(:facts, :loading)
         |> start_async(:load_facts, fn -> Inventory.facts_for(id) end)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Node not found")
         |> push_navigate(to: ~p"/inventory")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :tab, params["tab"] || "facts")}
  end

  @impl true
  def handle_async(:load_facts, {:ok, {:ok, rows}}, socket) do
    {:noreply, assign(socket, :facts, {:loaded, rows})}
  end

  def handle_async(:load_facts, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, :facts, {:error, format_error(reason)})}
  end

  def handle_async(:load_facts, {:exit, reason}, socket) do
    {:noreply, assign(socket, :facts, {:error, format_error(reason)})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto p-4">
      <Layouts.flash_group flash={@flash} />

      <div class="mb-6">
        <.link navigate={~p"/inventory"} class="link text-sm">← Inventory</.link>
        <h1 class="text-2xl font-bold mt-2 flex items-center gap-3">
          {@node.name}
          <span class="badge badge-ghost text-sm" title={@node.source.plugin_id}>
            {@node.source.integration_name}
          </span>
          <span :if={!@node.targetable?} class="badge badge-warning badge-sm">
            wildcard (not targetable)
          </span>
        </h1>
      </div>

      <div role="tablist" class="tabs tabs-bordered mb-4">
        <span role="tab" class="tab tab-active">Facts</span>
      </div>

      <div>
        <div :if={@facts == :loading} class="text-base-content/50 py-8 text-center">
          Loading facts from {@node.source.integration_name}…
        </div>

        <div :if={match?({:error, _}, @facts)} class="alert alert-error">
          <span>Facts unavailable: {elem(@facts, 1)}</span>
        </div>

        <div :if={@facts == {:loaded, []}} class="text-base-content/50 py-8 text-center">
          No facts reported for this node.
        </div>

        <table :if={loaded_rows(@facts) != []} class="table w-full" id="facts-table">
          <thead>
            <tr>
              <th>Key</th>
              <th>Value</th>
              <th>Source</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- loaded_rows(@facts)} id={"fact-#{row.key}"}>
              <td class="font-mono text-sm">{row.key}</td>
              <td class="text-sm">{fact_value(row.value)}</td>
              <td>
                <span
                  :for={src <- row.sources}
                  class="badge badge-ghost badge-sm"
                  title={src.plugin_id}
                >
                  {src.integration_name}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp loaded_rows({:loaded, rows}), do: rows
  defp loaded_rows(_), do: []

  defp fact_value(value) when is_binary(value), do: value
  defp fact_value(value) when is_number(value), do: to_string(value)
  defp fact_value(value), do: inspect(value)

  defp format_error(%Vigil.Plugin.Error{message: message}), do: message
  defp format_error(:unsupported), do: "this node's source does not provide facts"
  defp format_error(:not_found), do: "node not found"
  defp format_error(other), do: inspect(other)
end

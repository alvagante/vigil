defmodule VigilWeb.InventoryLive do
  @moduledoc """
  Unified inventory page (design §9.6.1) — issue #6.
  Route: /inventory

  Renders nodes aggregated across enabled inventory-capable integrations, each
  row carrying source attribution (`INV-201`). Per-source status is summarised
  at the top so a down source is visible rather than silently missing
  (`ERR-*`). Filtering, debounced search, URL-reflected filters, and 10k-node
  streaming are later UI work; this is the first concrete render of real
  integration data.
  """

  use VigilWeb, :live_view

  alias VigilWeb.Inventory

  @impl true
  def mount(_params, _session, socket) do
    inventory = Inventory.list_inventory()

    {:ok,
     socket
     |> assign(:page_title, "Inventory")
     |> assign(:nodes, inventory.nodes)
     |> assign(:sources, inventory.sources)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto p-4">
      <Layouts.flash_group flash={@flash} />
      <h1 class="text-2xl font-bold mb-6">Inventory</h1>

      <div :if={@sources != []} class="mb-4 flex flex-wrap gap-2 text-sm">
        <span class="text-base-content/60">Sources:</span>
        <span :for={source <- @sources} class={"badge #{source_badge_class(source.status)}"}>
          {source.integration_name} ({source.plugin_id})
          <span :if={match?({:error, _}, source.status)}>— unavailable</span>
          <span :if={source.status == :ok}>— {source.count}</span>
        </span>
      </div>

      <table :if={@nodes != []} class="table table-zebra w-full" id="inventory-table">
        <thead>
          <tr>
            <th>Node</th>
            <th>Identity</th>
            <th>Source</th>
            <th>Targetable</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={node <- @nodes} id={"node-#{node.id}"}>
            <td>
              <.link navigate={~p"/inventory/node/#{node.id}"} class="link link-primary font-medium">
                {node.name}
              </.link>
            </td>
            <td class="text-sm text-base-content/70">{identity(node.attributes)}</td>
            <td>
              <span class="badge badge-ghost" title={node.source.plugin_id}>
                {node.source.integration_name}
              </span>
            </td>
            <td>
              <span :if={node.targetable?} class="badge badge-success badge-sm">yes</span>
              <span
                :if={!node.targetable?}
                class="badge badge-ghost badge-sm"
                title="Wildcard pattern (SSH-103)"
              >
                no
              </span>
            </td>
          </tr>
        </tbody>
      </table>

      <div :if={@nodes == [] and @sources == []} class="text-center text-base-content/50 py-12">
        No inventory sources are enabled. Enable an inventory-capable integration in
        <.link navigate={~p"/settings/integrations"} class="link">Settings → Integrations</.link>
        to begin.
      </div>

      <div :if={@nodes == [] and @sources != []} class="text-center text-base-content/50 py-12">
        No nodes reported by the enabled inventory sources.
      </div>
    </div>
    """
  end

  defp identity(attributes) do
    host = attributes["hostname"]
    port = attributes["port"]

    cond do
      host && port -> "#{host}:#{port}"
      host -> host
      true -> "—"
    end
  end

  defp source_badge_class(:ok), do: "badge-success"
  defp source_badge_class({:error, _}), do: "badge-error"
  defp source_badge_class(_), do: "badge-ghost"
end

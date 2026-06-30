defmodule VigilWeb.NodeDetailLive do
  @moduledoc """
  Per-node detail page (design §9.6.2).
  Routes: /inventory/node/:id and /inventory/node/:id/:tab

  Tabs: Facts (async load from integration), Journal (local Postgres immediately +
  live PubSub updates + async external fetch per design §7).
  """

  use VigilWeb, :live_view

  alias Vigil.Core.Journal
  alias VigilWeb.Inventory

  @default_journal_filters %{}

  @impl true
  def mount(%{"id" => id} = _params, _session, socket) do
    case Inventory.get_node(id) do
      {:ok, node} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Vigil.PubSub, "journal:node:#{node.name}")
        end

        {:ok,
         socket
         |> assign(:page_title, node.name)
         |> assign(:node, node)
         |> assign(:facts, :loading)
         |> assign(:journal_filters, @default_journal_filters)
         |> assign(:journal_entries, [])
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
    tab = params["tab"] || "facts"
    socket = assign(socket, :tab, tab)

    socket =
      if tab == "journal" do
        node_id = socket.assigns.node.name
        filters = socket.assigns.journal_filters
        entries = Journal.local_entries(node_id, filters)
        assign(socket, :journal_entries, entries)
      else
        socket
      end

    {:noreply, socket}
  end

  # ── Facts async ──────────────────────────────

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

  # ── Journal PubSub ───────────────────────────

  @impl true
  def handle_info({:journal_entry_created, entry}, socket) do
    if socket.assigns.tab == "journal" do
      entries = [entry | socket.assigns.journal_entries]
      {:noreply, assign(socket, :journal_entries, entries)}
    else
      {:noreply, socket}
    end
  end

  # ── Journal filter events ────────────────────

  @impl true
  def handle_event("journal_filter", params, socket) do
    filters =
      %{}
      |> maybe_put(:entry_type, params["entry_type"])
      |> maybe_put(:severity, params["severity"])

    node_id = socket.assigns.node.name
    entries = Journal.local_entries(node_id, filters)

    {:noreply,
     socket
     |> assign(:journal_filters, filters)
     |> assign(:journal_entries, entries)}
  end

  # ── Template ─────────────────────────────────

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
        <.link
          navigate={~p"/inventory/node/#{@node.id}"}
          role="tab"
          class={"tab #{if @tab == "facts", do: "tab-active"}"}
        >
          Facts
        </.link>
        <.link
          navigate={~p"/inventory/node/#{@node.id}/journal"}
          role="tab"
          class={"tab #{if @tab == "journal", do: "tab-active"}"}
        >
          Journal
        </.link>
      </div>

      <div :if={@tab == "facts"}>
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

      <div :if={@tab == "journal"}>
        <form phx-change="journal_filter" class="flex gap-3 mb-4">
          <select name="entry_type" class="select select-bordered select-sm">
            <option value="">All types</option>
            <option value="execution" selected={@journal_filters[:entry_type] == "execution"}>
              Executions
            </option>
            <option value="manual_note" selected={@journal_filters[:entry_type] == "manual_note"}>
              Notes
            </option>
          </select>
          <select name="severity" class="select select-bordered select-sm">
            <option value="">All severities</option>
            <option value="informational" selected={@journal_filters[:severity] == "informational"}>
              Informational
            </option>
            <option value="notice" selected={@journal_filters[:severity] == "notice"}>
              Notice
            </option>
            <option value="warning" selected={@journal_filters[:severity] == "warning"}>
              Warning
            </option>
            <option value="error" selected={@journal_filters[:severity] == "error"}>
              Error
            </option>
          </select>
        </form>

        <div :if={@journal_entries == []} class="text-base-content/50 py-8 text-center">
          No journal entries yet for this node.
        </div>

        <div id="journal-entries" class="space-y-2">
          <div
            :for={entry <- @journal_entries}
            id={"journal-entry-#{entry.id}"}
            class="card card-bordered p-3"
          >
            <div class="flex items-start gap-3">
              <span class={"badge badge-sm #{severity_class(entry.severity)}"}>
                {entry.severity}
              </span>
              <div class="flex-1 min-w-0">
                <p class="text-sm font-medium">{entry.summary}</p>
                <p class="text-xs text-base-content/50 mt-1">
                  {entry.entry_type} · {format_datetime(entry.occurred_at)}
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Helpers ───────────────────────────────────

  defp loaded_rows({:loaded, rows}), do: rows
  defp loaded_rows(_), do: []

  defp fact_value(value) when is_binary(value), do: value
  defp fact_value(value) when is_number(value), do: to_string(value)
  defp fact_value(value), do: inspect(value)

  defp format_error(%Vigil.Plugin.Error{message: message}), do: message
  defp format_error(:unsupported), do: "this node's source does not provide facts"
  defp format_error(:not_found), do: "node not found"
  defp format_error(other), do: inspect(other)

  defp severity_class("error"), do: "badge-error"
  defp severity_class("warning"), do: "badge-warning"
  defp severity_class("notice"), do: "badge-info"
  defp severity_class(_), do: "badge-ghost"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end

  defp format_datetime(_), do: "—"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

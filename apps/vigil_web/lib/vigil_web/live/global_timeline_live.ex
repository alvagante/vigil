defmodule VigilWeb.GlobalTimelineLive do
  @moduledoc """
  Global journal timeline across all nodes (design §7.6.4, JRN-101/102/103).

  Local Postgres entries load on mount; free-text search is client-side only
  via JournalFilter hook (JRN-103, design §7.9.1). Server-side filters cover
  node_id, entry_type, severity, and time_range (JRN-102).

  External source entries are deferred (design §7 fetch-on-demand, noted in
  journal-scope memory).
  """

  use VigilWeb, :live_view

  alias Vigil.Core.Journal

  @default_filters %{}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Vigil.PubSub, "journal:global")
    end

    entries = Journal.local_entries_global(@default_filters)

    {:ok,
     socket
     |> assign(:page_title, "Journal")
     |> assign(:filters, @default_filters)
     |> assign(:entries, entries)}
  end

  # ── PubSub ────────────────────────────────────

  @impl true
  def handle_info({:journal_entry_created, entry}, socket) do
    {:noreply, assign(socket, :entries, [entry | socket.assigns.entries])}
  end

  def handle_info({:journal_entry_deleted, deleted}, socket) do
    entries = Enum.reject(socket.assigns.entries, &(&1.id == deleted.id))
    {:noreply, assign(socket, :entries, entries)}
  end

  # ── Filter events ─────────────────────────────

  @impl true
  def handle_event("journal_filter", params, socket) do
    filters =
      %{}
      |> maybe_put(:node_id, params["node_id"])
      |> maybe_put(:entry_type, params["entry_type"])
      |> maybe_put(:severity, params["severity"])

    entries = Journal.local_entries_global(filters)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:entries, entries)}
  end

  # ── Template ──────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto p-4">
      <Layouts.flash_group flash={@flash} />

      <div class="mb-6">
        <h1 class="text-2xl font-bold">Journal</h1>
        <p class="text-base-content/60 text-sm mt-1">
          All activity across nodes — executions, manual notes, and events.
        </p>
      </div>

      <form phx-change="journal_filter" class="flex flex-wrap gap-3 mb-4">
        <input
          type="text"
          name="text_filter"
          placeholder="Filter entries…"
          class="input input-bordered input-sm flex-1 min-w-40"
          phx-debounce="0"
          id="journal-text-filter"
        />
        <input type="text" name="node_id" placeholder="Node" class="input input-bordered input-sm w-36"
          value={@filters[:node_id] || ""} />
        <select name="entry_type" class="select select-bordered select-sm">
          <option value="">All types</option>
          <option value="execution" selected={@filters[:entry_type] == "execution"}>Executions</option>
          <option value="manual_note" selected={@filters[:entry_type] == "manual_note"}>Notes</option>
        </select>
        <select name="severity" class="select select-bordered select-sm">
          <option value="">All severities</option>
          <option value="informational" selected={@filters[:severity] == "informational"}>
            Informational
          </option>
          <option value="notice" selected={@filters[:severity] == "notice"}>Notice</option>
          <option value="warning" selected={@filters[:severity] == "warning"}>Warning</option>
          <option value="error" selected={@filters[:severity] == "error"}>Error</option>
        </select>
      </form>

      <div
        id="journal-global-entries"
        class="space-y-2"
        phx-hook="JournalFilter"
        data-filter-input="#journal-text-filter"
      >
        <div :if={@entries == []} class="text-base-content/50 py-8 text-center">
          No journal entries yet.
        </div>

        <div
          :for={entry <- @entries}
          id={"global-entry-#{entry.id}"}
          class="card card-bordered p-3"
          data-searchable={entry_searchable_text(entry)}
        >
          <div class="flex items-start gap-3">
            <span class={"badge badge-sm #{severity_class(entry.severity)}"}>
              {entry.severity}
            </span>
            <div class="flex-1 min-w-0">
              <p class="text-sm font-medium">{entry.summary}</p>
              <p class="text-xs text-base-content/50 mt-1">
                <span class="font-mono">{entry.node_id}</span>
                · {entry.entry_type}
                · {format_datetime(entry.occurred_at)}
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Helpers ───────────────────────────────────

  defp entry_searchable_text(entry) do
    [entry.node_id, entry.summary, entry.entry_type]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp severity_class("error"), do: "badge-error"
  defp severity_class("warning"), do: "badge-warning"
  defp severity_class("notice"), do: "badge-info"
  defp severity_class(_), do: "badge-ghost"

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  defp format_datetime(_), do: "—"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

# 7. Journal & Events

This section realizes PRD sections 4.10 (journal contribution rules), 11.3 (per-node journal, global timeline, manual notes, linking), and `TYPE-JRN-*`, `JRN-*`, `DM-501..503`.

The journal is the per-node operational history. It's how an operator answers "what changed?". It must be accurate (reflects what the source actually reported), complete (shows all contributing sources), grouped correctly (events from one run stay together), and responsive to render.

> **Decision: Fetch-on-demand, not store-and-forward.**
> External events (Puppet reports, monitoring transitions, cloud lifecycle, deployments) are fetched from the source tool's API when the user views the journal. Vigil does NOT maintain a local copy of external events. Only Vigil-originated data (execution results, manual notes) is persisted in PostgreSQL. This keeps the source tool as the single source of truth, avoids data duplication, eliminates ingestion pipelines, and removes retention policy conflicts between Vigil and upstream tools.

## 7.1 Architecture overview

```
User opens journal
        │
        ▼
┌─────────────────────────────────────────────────────────┐
│  LiveView mount                                          │
│                                                          │
│  1. Query local Postgres (executions + manual notes)     │  ← immediate (~5ms)
│  2. Kick off async fetches to each integration           │
│                                                          │
│     ┌──────────────┐  ┌──────────────┐  ┌────────────┐ │
│     │ PuppetDB API │  │ Monitoring   │  │ CloudTrail │ │
│     │ (events)     │  │ API          │  │ API        │ │
│     └──────┬───────┘  └──────┬───────┘  └─────┬──────┘ │
│            │                  │                 │        │
│  3. As each responds → merge into timeline, re-render   │
│                                                          │
│  4. All done → remove loading indicators                 │
└─────────────────────────────────────────────────────────┘
```

## 7.2 What is stored locally (PostgreSQL)

Only data where Vigil is the originating source:

| Data | Why stored locally |
|------|-------------------|
| **Execution results** | Vigil initiates and owns the execution; no external tool has this data |
| **Manual notes** | User-authored content; Vigil is the only source |
| **Audit trail** | Platform-internal accountability record |
| **Linking decisions** | Manual link/unlink overrides |

These use the `journal_entries` table (for executions and notes) and `audit_entries` (for audit).

```sql
CREATE TABLE journal_entries (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL,
  node_id         UUID NOT NULL REFERENCES nodes(id),
  entry_type      TEXT NOT NULL,          -- 'execution' | 'manual_note'
  summary         TEXT NOT NULL,
  detail          JSONB,
  severity        TEXT NOT NULL DEFAULT 'informational',
  occurred_at     TIMESTAMPTZ NOT NULL,
  -- Execution-specific
  execution_id    UUID REFERENCES executions(id),
  -- Manual note-specific
  author_user_id  UUID REFERENCES users(id),
  -- Metadata
  inserted_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at      TIMESTAMPTZ
);

CREATE INDEX journal_entries_node_time ON journal_entries (node_id, occurred_at DESC);
CREATE INDEX journal_entries_type ON journal_entries (entry_type);
```

## 7.3 What is fetched on-demand (never stored)

All external event data — fetched from the source tool's API when the user views the journal:

| Source | API call | Filters passed |
|--------|----------|----------------|
| PuppetDB events | `GET /pdb/query/v4/events` with time range + certname | Time range, node certname |
| Monitoring transitions | Tool-specific API (Icinga, Nagios, etc.) | Time range, host |
| AWS CloudTrail | `LookupEvents` with time range + resource | Time range, instance ID |
| Azure Activity Log | Activity Log API with time range + resource | Time range, resource ID |
| Proxmox task log | `GET /api2/json/nodes/{node}/tasks` | Time range |
| Deployment events | Tool-specific (ArgoCD, etc.) | Time range, target |

Each plugin's Events capability implements a `fetch_events/3` function:

```elixir
@callback fetch_events(config :: map(), node_id :: String.t(), opts :: keyword()) ::
  {:ok, [normalized_event()]} | {:error, term()}

@type normalized_event :: %{
  source_event_id: String.t(),
  occurred_at: DateTime.t(),
  entry_type: String.t(),
  summary: String.t(),
  severity: :informational | :notice | :warning | :error,
  detail: map(),
  group_key: String.t() | nil,
  references: map()
}
```

## 7.4 Event normalization

Each plugin normalizes its source's event format to the common `normalized_event` shape. This happens at fetch time, not at ingestion time (there is no ingestion).

### 7.4.1 Puppet event extraction

```elixir
defmodule Vigil.Integrations.Puppet.EventNormalizer do
  def normalize_events(raw_events, integration) do
    raw_events
    |> Enum.filter(&changed?/1)           # skip noop (TYPE-EVT-004)
    |> Enum.map(&to_normalized(&1, integration))
  end

  defp changed?(event), do: event["status"] in ["success", "failure"]

  defp to_normalized(event, integration) do
    %{
      source_event_id: event["report"] <> ":" <> event["resource_title"],
      occurred_at: parse_timestamp(event["timestamp"]),
      entry_type: "configuration_change",
      summary: "#{event["resource_type"]}[#{event["resource_title"]}]: #{event["message"]}",
      severity: if(event["status"] == "failure", do: :error, else: :informational),
      detail: %{
        resource_type: event["resource_type"],
        resource_title: event["resource_title"],
        old_value: event["old_value"],
        new_value: event["new_value"],
        file: event["file"],
        line: event["line"],
        containment_path: event["containment_path"]
      },
      group_key: event["report"],
      references: %{report_id: event["report"]}
    }
  end
end
```

### 7.4.2 Monitoring state transition detection

For monitoring, the plugin fetches current and recent state from the monitoring tool's API. State transitions are derived by comparing consecutive check results:

```elixir
defmodule Vigil.Integrations.Icinga.EventNormalizer do
  def normalize_transitions(state_history, integration) do
    state_history
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [prev, curr] -> prev["state"] != curr["state"] end)
    |> Enum.map(fn [prev, curr] -> to_transition(prev, curr, integration) end)
  end

  defp to_transition(prev, curr, _integration) do
    %{
      source_event_id: "#{curr["host"]}:#{curr["service"]}:#{curr["timestamp"]}",
      occurred_at: parse_timestamp(curr["timestamp"]),
      entry_type: "monitoring_transition",
      summary: "#{curr["service"]}: #{prev["state"]} → #{curr["state"]}",
      severity: severity_for(curr["state"]),
      detail: %{
        check: curr["service"],
        previous_state: prev["state"],
        new_state: curr["state"],
        output: curr["output"]
      },
      group_key: nil,
      references: %{}
    }
  end
end
```

### 7.4.3 Severity mapping

Each plugin maps its source's severity/status concept to Vigil's four levels:

| Level | Meaning | Examples |
|-------|---------|----------|
| `:informational` | Normal operation, successful change | Puppet resource applied, VM started, deployment succeeded |
| `:notice` | Noteworthy but not problematic | Monitoring recovery, noop change (if shown) |
| `:warning` | Potential issue, not yet critical | Monitoring warning state, resource corrective change |
| `:error` | Failure requiring attention | Puppet resource failed, monitoring critical, provisioning failed |

## 7.5 Journal contribution rules

Per PRD section 4.10, strictly enforced at the plugin level:

| Type | Journal contribution | Fetch behavior |
|------|---------------------|----------------|
| Inventory | None | Not fetched for journal |
| Facts | None | Not fetched for journal |
| Configuration | None | Not fetched for journal |
| Events | One entry per event | Fetched on-demand from source API |
| Monitoring | One entry per state *change* | Transitions derived from source's state history API |
| Reports | One entry per change event; none for no-op | Events extracted from report data fetched on-demand |
| Remote Execution | One per target per execution | Stored locally (Vigil-originated) |
| Provisioning | One per lifecycle action | Fetched on-demand from source's event/task log |
| Deployment | One per deploy event | Fetched on-demand from source API |

## 7.6 LiveView implementation

### 7.6.1 Per-node journal

```elixir
defmodule VigilWeb.NodeJournalLive do
  use VigilWeb, :live_view

  def mount(%{"node_id" => node_id}, _session, socket) do
    node = Vigil.Core.Inventory.get_node!(node_id)
    filters = default_filters()

    # Immediate: local entries from Postgres
    local_entries = Vigil.Core.Journal.local_entries(node_id, filters)
    integrations = journal_capable_integrations(node)

    socket =
      socket
      |> assign(:node, node)
      |> assign(:filters, filters)
      |> assign(:pending_sources, MapSet.new(Enum.map(integrations, & &1.id)))
      |> assign(:failed_sources, %{})
      |> stream(:entries, local_entries)

    # Async: fetch from each integration
    if connected?(socket) do
      for int <- integrations do
        send(self(), {:fetch_events, int})
      end
    end

    {:ok, socket}
  end

  def handle_info({:fetch_events, integration}, socket) do
    node = socket.assigns.node
    filters = socket.assigns.filters

    Task.Supervisor.start_child(Vigil.TaskSupervisor, fn ->
      result = fetch_integration_events(integration, node, filters)
      send(socket.root_pid, {:events_arrived, integration.id, result})
    end)

    {:noreply, socket}
  end

  def handle_info({:events_arrived, integration_id, {:ok, entries}}, socket) do
    socket =
      socket
      |> stream_batch_insert_sorted(:entries, entries)
      |> update(:pending_sources, &MapSet.delete(&1, integration_id))

    {:noreply, socket}
  end

  def handle_info({:events_arrived, integration_id, {:error, reason}}, socket) do
    socket =
      socket
      |> update(:pending_sources, &MapSet.delete(&1, integration_id))
      |> update(:failed_sources, &Map.put(&1, integration_id, reason))

    {:noreply, socket}
  end

  # Manual refresh
  def handle_event("refresh", _params, socket) do
    {:noreply, trigger_refresh(socket)}
  end

  # Auto-refresh toggle
  def handle_event("toggle_auto_refresh", %{"interval" => interval}, socket) do
    case interval do
      "off" ->
        if socket.assigns[:refresh_timer], do: Process.cancel_timer(socket.assigns.refresh_timer)
        {:noreply, assign(socket, auto_refresh: false, refresh_timer: nil)}
      seconds ->
        ms = String.to_integer(seconds) * 1_000
        timer = Process.send_after(self(), :auto_refresh_tick, ms)
        {:noreply, assign(socket, auto_refresh: true, refresh_interval_ms: ms, refresh_timer: timer)}
    end
  end

  def handle_info(:auto_refresh_tick, socket) do
    socket = trigger_refresh(socket)
    timer = Process.send_after(self(), :auto_refresh_tick, socket.assigns.refresh_interval_ms)
    {:noreply, assign(socket, refresh_timer: timer)}
  end

  defp trigger_refresh(socket) do
    integrations = journal_capable_integrations(socket.assigns.node)

    socket
    |> assign(:pending_sources, MapSet.new(Enum.map(integrations, & &1.id)))
    |> assign(:failed_sources, %{})
    |> tap(fn _ ->
      for int <- integrations, do: send(self(), {:fetch_events, int})
    end)
  end
end
```

### 7.6.2 Progressive rendering UX

The user sees:

1. **Instant** (< 50ms): local entries (executions, notes) rendered immediately. Loading indicators per external source.
2. **Progressive** (100-500ms per source): entries merge into the timeline as each source responds. Timeline re-sorts by `occurred_at`.
3. **Complete** (1-2s total): all loading indicators removed. Failed sources show "unavailable" marker with the integration name.

Entries arriving from a slow source may be chronologically older than already-rendered entries — they insert at the correct position in the sorted timeline. LiveView streams handle this efficiently.

### 7.6.3 Decommissioned-node journal notice (JRN-202 / DM-1108)

When the viewed node's `lifecycle_state` is `:decommissioned`, the journal LiveView surfaces a persistent banner at the top of the timeline explaining the source-retention consequence spelled out in `JRN-202` and `DM-1108`. Vigil does not archive external events on decommission — external journal history for a decommissioned node is only available for as long as the upstream tool retains it.

`mount/3` adds a `decommissioned?` assign derived from the node row; the template renders the banner conditionally:

```elixir
def mount(%{"node_id" => node_id}, _session, socket) do
  node = Vigil.Core.Inventory.get_node!(node_id)
  # ... existing assigns ...
  {:ok, socket
        |> assign(:node, node)
        |> assign(:decommissioned?, node.lifecycle_state == :decommissioned)
        # ... other assigns ...
        }
end
```

```heex
<.callout :if={@decommissioned?} kind={:warning} dismissible={false}>
  <:title>This node is decommissioned</:title>
  Vigil-originated entries (executions, manual notes) below are preserved indefinitely
  (`DM-1108`). External events from <%= integration_names(@node) %> appear only while
  the upstream tools still retain them; Vigil does not archive external events on
  decommission. Configure source-side retention
  (e.g. PuppetDB <code>node-purge-ttl</code>, CloudTrail retention) if long-term external
  history is required.
</.callout>
```

Three behavioural details:

- The banner is **not dismissible**. The retention caveat is operationally important enough that a "don't show again" affordance would create the wrong incentive. A reviewer opening this page weeks after the decommission needs to see the notice.
- The banner is **per-node**, not global — a decommissioned node's journal page shows it; other pages do not. The text adapts to which journal-contributing integrations the node was attributed to before decommission (sourced from the retained `node_sources` rows).
- When a fetch from a still-configured integration fails (the upstream has purged the node, returning empty or a 404), the per-source unavailable marker rendered by `pending_sources` / `failed_sources` is the *expected* state — the banner above contextualises it as a retention consequence rather than a fault.

For local entries (executions, manual notes) the timeline behaves normally — these are persisted indefinitely (`DM-1103`, `DM-1108`) and continue to render after decommission without any caveat.

### 7.6.4 Global timeline

Same pattern as per-node, but queries each source for "recent events across all nodes" within the selected time range. Additional filters (node, group, severity) are passed to source APIs where supported, or applied post-fetch.

```elixir
def mount(_params, _session, socket) do
  filters = %{time_range: last_24h(), severity: nil, source: nil, node: nil}
  local_entries = Vigil.Core.Journal.local_entries_global(filters)
  integrations = all_journal_capable_integrations()

  # Same progressive pattern as per-node
  ...
end
```

## 7.7 Manual notes

Manual notes are the one journal entry type that is fully CRUD-managed locally:

```elixir
defmodule Vigil.Core.Journal.Notes do
  def create(principal, %{node_id: node_id, summary: summary, detail: detail, tags: tags}) do
    with :ok <- RBAC.check(principal, "journal:note:create", node_id) do
      %JournalEntry{}
      |> JournalEntry.changeset(%{
        node_id: node_id,
        entry_type: "manual_note",
        summary: summary,
        detail: Map.put(detail || %{}, "tags", tags),
        author_user_id: principal.id,
        severity: "notice",
        occurred_at: DateTime.utc_now()
      })
      |> Repo.insert()
    end
  end

  def update(principal, entry_id, changes) do
    entry = Repo.get!(JournalEntry, entry_id)
    with :ok <- authorize_edit(principal, entry) do
      Repo.transaction(fn ->
        Repo.insert!(%JournalNoteRevision{
          journal_entry_id: entry.id,
          editor_user_id: principal.id,
          previous_summary: entry.summary,
          previous_detail: entry.detail
        })
        Repo.update!(JournalEntry.changeset(entry, changes))
      end)
    end
  end
end
```

`authorize_edit/2` implements `DM-501`: only the author may modify their own manual note; all edits produce a revision row.

## 7.8 Execution journal entries

When an execution completes, the `Execution.Stream` GenServer writes one journal entry per target node:

```elixir
defmodule Vigil.Core.Execution.Completion do
  def record_journal_entries(execution) do
    for target <- execution.targets do
      Vigil.Core.Journal.create_execution_entry(%{
        node_id: target.node_id,
        execution_id: execution.id,
        summary: "#{execution.artifact_type}: #{execution.artifact_name}",
        severity: severity_for_exit(target.exit_status),
        occurred_at: execution.completed_at,
        detail: %{
          exit_status: target.exit_status,
          duration_ms: target.duration_ms,
          integration_id: execution.integration_id,
          initiating_user: execution.user_id
        }
      })
    end
  end
end
```

These entries are stored locally and appear immediately in the journal (no fetch needed).

## 7.9 Filtering

Filters are applied at different levels depending on where the data lives:

| Filter | Local entries | External entries |
|--------|--------------|-----------------|
| Time range | SQL `WHERE occurred_at BETWEEN ...` | Passed to upstream API query |
| Source/integration | SQL `WHERE` or skip query | Controls which APIs are called |
| Severity | SQL `WHERE severity = ...` | Applied post-fetch after normalization |
| Entry type | SQL `WHERE entry_type = ...` | Applied post-fetch after normalization |
| Node (global view) | SQL `WHERE node_id = ...` | Passed to upstream API where supported |
| Group (global view) | SQL join on group membership | Resolve group → node list, then filter |
| Free text | Not applied server-side | Client-side browser filtering only |

### 7.9.1 Client-side text filtering

A LiveView.JS hook provides instant text filtering of rendered entries without a server round-trip:

```javascript
// assets/js/hooks/journal_filter.js
export const JournalFilter = {
  mounted() {
    this.el.addEventListener("input", (e) => {
      const query = e.target.value.toLowerCase()
      document.querySelectorAll("[data-journal-entry]").forEach(el => {
        const text = el.textContent.toLowerCase()
        el.style.display = text.includes(query) ? "" : "none"
      })
    })
  }
}
```

This covers the "search within what's loaded" use case. For deep historical search, operators use the source tool's native interface.

## 7.10 Visibility and RBAC

RBAC scoping for journal entries:

```elixir
defp visible_integrations(principal) do
  RBAC.allowed_integration_ids(principal, "journal:read")
end
```

- Local entries (executions, notes): filtered by node visibility in the SQL query.
- External entries: only fetched from integrations the user has `journal:read` permission on. If a user can't see a source, it's never queried.

## 7.11 Back-references

Each journal entry (local or fetched) carries a `references` map:

```elixir
%{
  report_id: "uuid-of-puppet-report",      # → navigates to report detail view
  execution_id: "uuid-of-execution",        # → navigates to execution transcript
  external_url: "https://..."               # → deep link out (marked as external)
}
```

The UI resolves these to links. For external events, the `report_id` or equivalent can navigate to Vigil's report detail view (which itself fetches the report on-demand from the source).

## 7.12 What we explicitly removed

Compared to earlier designs, this architecture eliminates:

- **Event pollers** — no background processes fetching events on a schedule
- **Webhook handlers for journal ingestion** — webhooks may exist for other purposes (cache invalidation, execution triggers) but not for populating the journal
- **Journal ingestor (Oban worker)** — no write pipeline for external events
- **Checkpoint tracking** — no need to track "last processed event ID" per source
- **Deduplication logic** — no local store means no dedup needed (source is authoritative)
- **Journal retention jobs for external data** — the source tool manages its own retention
- **Full-text search index (tsvector)** — replaced by client-side filtering
- **PubSub broadcast for new journal entries from external sources** — no auto-refresh

## 7.13 Performance

Expected latency for journal rendering:

| Scenario | Expected latency |
|----------|-----------------|
| Local entries (executions + notes) | < 50ms |
| Single external source (PuppetDB events for one node) | 100-300ms |
| All sources for one node (3-4 integrations) | 500ms-1.5s total (progressive) |
| Global timeline (all sources, recent window) | 1-2s total (progressive) |

These are acceptable for a 5-user ops team. The progressive rendering pattern means the user sees *something* immediately and the view fills in over 1-2 seconds.

### 7.13.1 Short-term ETS cache for navigation

To avoid re-fetching when a user navigates away and back within seconds, fetched external events are cached briefly in ETS (30-60s TTL, keyed by `{integration_id, node_id, filter_hash}`). This is a UX optimization, not a data persistence mechanism. The cache is never served stale — on expiry, the next view triggers a fresh fetch.

## 7.14 Graceful degradation

When an external source is unavailable:

1. Local entries still render immediately.
2. The failed source shows a clear marker: "PuppetDB events unavailable — source unreachable."
3. Other sources that responded successfully are shown normally.
4. The user can retry the failed source via the refresh button.

This is honest — the user sees exactly what's available and what isn't. No stale copies masquerading as current data.

## 7.15 Testing

Property-based tests (`TEST-203`) for event normalization:

- Synthetic Puppet events with varying mixes of changes and noops → normalizer never emits noops.
- Events from one report → all share the `group_key`.
- Monitoring state history → transitions detected correctly, steady state produces no entries.

Integration tests:

- Create manual note, verify it appears in per-node and global timelines.
- Submit execution, verify journal entries appear immediately (local).
- Mock external API responses, verify progressive rendering merges correctly.
- Simulate source failure, verify degraded state marker appears.

LiveView tests:

- Mount journal, verify local entries render immediately.
- Verify async messages merge entries in correct chronological order.
- Verify filter controls pass parameters to fetch functions.
- Verify refresh button re-triggers fetches.

---

[← Previous: Execution & Streaming](06-execution-and-streaming.md) | [Next: Auth & RBAC →](08-auth-rbac.md)

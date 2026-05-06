# 7. Journal & Events

This section realizes PRD sections 4.10 (journal contribution rules), 11.3 (per-node journal, global timeline, manual notes, linking), and `TYPE-JRN-*`, `JRN-*`, `DM-501..503`.

The journal is the per-node operational history. It's how an operator answers "what changed?". It must be accurate (reflects what the source actually reported), complete (no dropped events), idempotent (re-ingestion doesn't duplicate), grouped correctly (events from one run stay together), and fast to query.

## 7.1 Pipeline overview

```
+-------------------+           +-----------------------+           +------------------+
|   Plugins / Event |--events-->| Vigil.Core.Journal    |--insert-->| journal_entries  |
|     Pollers       |           |     Ingestor (Oban)   |           | (PostgreSQL)     |
+-------------------+           +-----------+-----------+           +--------+---------+
     ^                                      |                                |
     |                                      | publish                        | triggers
     |                                      v                                v
     |                           +---------------------+         +----------------------+
     |                           |  Phoenix.PubSub     |         |  Full-text search    |
     |                           |  journal:global,    |         |  tsvector GIN        |
     |                           |  node:<id>          |         +----------------------+
     |                           +----------+----------+
     |                                      |
     |                                      v
     |                           +---------------------+
     |                           |  LiveView subscribers|
     |                           +---------------------+
     |
     +--webhook--+
                 |
     +-----------v-----------+
     |   Phoenix webhook     |
     |   controller          |
     |   (enqueues Oban job) |
     +-----------------------+
```

## 7.2 Ingestion sources

Journal entries arrive through three channels:

### 7.2.1 Event polling

Plugins that expose events via query (PuppetDB events, AWS CloudTrail, Azure Activity Log, Proxmox task log) have a poller worker started by the plugin supervisor:

```elixir
defmodule Vigil.Integrations.Puppet.EventPoller do
  use GenServer
  # Periodically fetches events since the last checkpoint.
  # Publishes normalized journal entries.
end
```

Each poller tracks a checkpoint (last processed event ID or timestamp) so it fetches only new events (`TYPE-EVT-006`, `PUP-607`). Checkpoints are persisted to avoid re-ingesting on restart.

### 7.2.2 Push (webhook / streaming)

For sources that push (Puppet webhooks on report arrival, ArgoCD webhook, monitoring webhooks):

```elixir
# apps/vigil_web/lib/vigil_web/controllers/webhook_controller.ex
def handle(conn, %{"integration_id" => id} = params) do
  with {:ok, integration} <- Vigil.Core.Inventory.get_integration(id),
       :ok <- verify_signature(integration, conn, params) do
    Oban.insert!(WebhookJob.new(%{integration_id: id, payload: params}))
    send_resp(conn, 202, "")
  end
end
```

The webhook controller accepts, verifies signature (HMAC typically), enqueues an Oban job, and returns 202. The Oban job runs the plugin's webhook handler, which normalizes to journal entries.

### 7.2.3 Internal producers

Executions (one entry per target) and manual notes (user-authored) produce entries directly via the journal context:

```elixir
Vigil.Core.Journal.create_manual_note(principal, node_id, %{
  summary: "Rebooted after incident I-2026-05-06-03",
  detail: %{tags: ["incident-2026-05-06-03"]}
})
```

## 7.3 Event extraction

The most delicate ingestion is event extraction from structured reports (`TYPE-EVT-004`, `TYPE-RPT-005`). A Puppet report produces multiple events, and the rules about what to extract are stringent:

- Only state transitions (`TYPE-EVT-004`): a resource `file[/etc/foo]` that changed is an event; one that was `noop` is not.
- Grouped under the source's group key (`TYPE-JRN-003`, `JRN-005`): all events from report `abc` share `group_key = "abc"`.
- Idempotent on re-ingest (`JRN-204`): replaying the same report doesn't create duplicates.

```elixir
defmodule Vigil.Integrations.Puppet.EventExtractor do
  def extract(report) do
    report.resource_statuses
    |> Enum.filter(&changed?/1)           # skip noop
    |> Enum.flat_map(&events_for_resource/1)
    |> Enum.map(&to_journal_entry(&1, report))
  end

  defp changed?(resource), do: resource.status in ["success", "failure"] and
                                resource.events != [] and
                                not all_noop?(resource.events)
end
```

The ingestor wraps insertion in a `ON CONFLICT DO NOTHING` on the unique idempotency index `(integration_id, source_event_id)`. Duplicates are silently skipped.

## 7.4 Journal ingestor

```elixir
defmodule Vigil.Core.Journal.Ingestor do
  use Oban.Worker, queue: :journal, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"integration_id" => id, "entries" => entries}}) do
    Ecto.Multi.new()
    |> Multi.insert_all(
      :entries,
      JournalEntry,
      Enum.map(entries, &normalize/1),
      on_conflict: :nothing,
      conflict_target: [:integration_id, :source_event_id]
    )
    |> Repo.transaction()
    |> publish_events()
  end

  defp publish_events({:ok, %{entries: {_count, inserted}}}) do
    for entry <- inserted do
      Phoenix.PubSub.broadcast(Vigil.PubSub, "journal:global", {:journal_entry, entry})
      if entry.node_id do
        Phoenix.PubSub.broadcast(Vigil.PubSub, "node:#{entry.node_id}", {:journal_entry, entry})
      end
    end
    :ok
  end
end
```

`insert_all` with `on_conflict: :nothing` is atomic and idempotent. Only actually-inserted rows are broadcast, so live-update subscribers never see dupes.

## 7.5 Journal contribution rules

The PRD is strict about which types produce journal entries (`4.10`):

| Type | Entry creation | Implementation |
|------|---------------|----------------|
| Inventory | None | Ingestor doesn't accept `:inventory` entries |
| Facts | None | Ingestor doesn't accept `:facts` entries |
| Configuration | None | Ingestor doesn't accept `:configuration` entries |
| Events | One per event | Plugin pollers/webhooks produce one entry per real event |
| Monitoring | One per state *change* | Monitoring workers diff state against last seen; entry only on transition |
| Reports | One per change event; none for no-op | Extractor filters noop; enforced in `changed?/1` predicate |
| Remote Execution | One per target per execution | Execution.Stream writes on completion |
| Provisioning | One per lifecycle action (from upstream event log) | EventLogPoller, not local inference |
| Deployment | One per deploy event | Plugin-specific poller/webhook |

The shape is enforced by the ingestor's typespec — it rejects journal entries whose `plugin_id + entry_type` combination isn't in the allowed matrix.

## 7.6 Monitoring state transition detection

For monitoring (`FLOW-601`, `TYPE-MON-003`), we need to detect transitions without storing the raw stream. The approach:

- A `MonitoringStateTracker` GenServer per integration holds last-known state per `{node_id, check}` in memory (and a backing table on disk for restart).
- On each observation, compare against last-known; if different, emit a journal entry for the transition.
- Steady-state observations do not produce entries (`FLOW-602`, `TYPE-MON-003`).

```elixir
defmodule Vigil.Integrations.Icinga.StateTracker do
  use GenServer

  def handle_cast({:observation, %{node_id: nid, check: c, state: new_state, ts: ts}}, state) do
    key = {nid, c}
    old_state = Map.get(state.last_known, key)

    if old_state && old_state != new_state do
      duration_ms = DateTime.diff(ts, old_state.since, :millisecond)
      Ingestor.enqueue(build_transition_entry(nid, c, old_state, new_state, duration_ms))
    end

    new_last = Map.put(state.last_known, key, %{state: new_state, since: ts})
    {:noreply, %{state | last_known: new_last}}
  end
end
```

Durations of prior-state are captured in the transition entry (`FLOW-603`).

## 7.7 Global timeline and per-node timeline

Per-node timeline:

```elixir
def node_timeline(principal, node_id, filters) do
  from(e in JournalEntry,
    where: e.node_id == ^node_id and is_nil(e.deleted_at),
    where: ^visibility_filter(principal),
    where: ^type_filter(filters),
    where: ^time_range(filters),
    order_by: [desc: e.occurred_at, desc: e.id],
    preload: [:integration]
  )
  |> cursor_paginate(filters.cursor, limit: 50)
end
```

Global timeline:

```elixir
def global_timeline(principal, filters) do
  from(e in JournalEntry,
    where: is_nil(e.deleted_at),
    where: ^visibility_filter(principal),
    where: ^type_filter(filters),
    where: ^time_range(filters),
    where: ^search_filter(filters),    # uses tsvector + @@ plainto_tsquery
    order_by: [desc: e.occurred_at, desc: e.id]
  )
  |> cursor_paginate(filters.cursor, limit: 50)
end
```

Cursor pagination uses `(occurred_at, id)` as the composite cursor. This avoids offset-based inconsistency under concurrent inserts (`INV-405`, mirrored for journal).

Full-text search uses the generated tsvector column and the `@@ plainto_tsquery(...)` operator. At the journal's expected volume, the GIN index on `search_text` keeps queries under 200ms.

### 7.7.1 Visibility filter

RBAC scoping for journal:

```elixir
defp visibility_filter(%Principal{} = principal) do
  allowed_integrations = RBAC.allowed_integration_ids(principal, "journal:read")
  allowed_node_ids_subq = node_visibility_subquery(principal)

  dynamic([e],
    e.integration_id in ^allowed_integrations or
    (e.entry_type == "manual_note" and e.node_id in subquery(allowed_node_ids_subq))
  )
end
```

A user can see journal entries for integrations they have read on, plus manual notes on nodes they can see.

## 7.8 Live updates to LiveView

Per-node journal LiveView:

```elixir
def mount(%{"node_id" => id}, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(Vigil.PubSub, "node:#{id}")
  end

  {:ok, socket
    |> assign(:node, load_node(id))
    |> stream(:entries, load_initial_entries(id))}
end

def handle_info({:journal_entry, entry}, socket) do
  if matches_filter?(entry, socket.assigns.filters) do
    {:noreply, stream_insert(socket, :entries, entry, at: 0)}
  else
    {:noreply, socket}
  end
end
```

`STR-603`: ordering preserved. `LiveView.stream` with `at: 0` inserts new entries at the top. If a backlog arrives during page load, the LiveView reconciles by sorting against the current visible cursor window.

## 7.9 Manual notes

```elixir
defmodule Vigil.Core.Journal.Notes do
  def create(principal, %{node_id: node_id, summary: summary, detail: detail, tags: tags}) do
    with :ok <- RBAC.check(principal, "journal:note:create", node_id) do
      %JournalEntry{}
      |> JournalEntry.changeset(%{
        node_id: node_id,
        entry_type: "manual_note",
        summary: summary,
        detail: Map.put(detail, "tags", tags),
        author_user_id: principal.id,
        severity: "notice",
        occurred_at: DateTime.utc_now(),
        source_event_id: "manual:#{Ecto.UUID.generate()}",
        plugin_id: nil,
        integration_id: nil
      })
      |> Repo.insert()
      |> broadcast_result()
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

The UI renders manual notes with a distinct visual style (`UI-406`, `JRN-304`) and shows the author and revision count.

## 7.10 Retention

Retention runs as a periodic Oban cron job:

```elixir
defmodule Vigil.Core.Journal.RetentionJob do
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    policy = Settings.retention_policy()

    from(e in JournalEntry,
      where: e.occurred_at < ^cutoff(policy.journal_days),
      where: e.entry_type != "manual_note"       # manual notes have their own policy
    )
    |> Repo.delete_all(timeout: :infinity)

    :ok
  end
end
```

Manual notes retain longer or indefinitely by default — they're operator knowledge, not machine chatter. `NFR-1104` requires explicit policy expiration; the default policy is `:unbounded`.

## 7.11 Back-references

Each journal entry that derives from a structured artifact carries a reference (`JRN-401`):

```json
"references": {
  "report_id": "uuid-of-puppet-report",
  "execution_id": null,
  "provisioning_op_id": null,
  "external_url": null
}
```

The UI resolves these to links. `UI-405` ("view source" affordance) is implemented as a button per entry that navigates to the relevant detail view. For external events (CloudTrail etc.), `JRN-403` permits a deep link out, clearly marked.

## 7.12 Search

Journal search combines:

- **Full-text search** on the tsvector column (English dictionary by default; per-tenant configuration overrides).
- **Structured filters** on `entry_type`, `integration_id`, `severity`, `time range`, `tags` (in detail JSONB).

The `search_text` tsvector covers summary + stringified detail, giving a single-column search surface. Tag search uses JSONB containment:

```elixir
where: fragment("?->'tags' @> ?::jsonb", e.detail, ^tag_list_json)
```

Combined search uses AND semantics across dimensions, OR within a dimension (`UI-204`).

## 7.13 Dedup semantics at the UI

`JRN-202` requires distinguishing *stored* entries from *live-fetched* entries without showing duplicates. Our design keeps all journal entries in Postgres after ingestion — there is no "live fetch at render time" for journal. The distinction in the PRD addresses designs that might fetch-on-demand; our ingest-first approach makes the dedup question trivial: entries are stored, period.

## 7.14 Performance

Expected volume for 10,000-node deployments:

- Puppet events: ~10,000 nodes × ~1 change/day × 30 days = 300,000 entries
- Executions: hundreds per day
- Monitoring transitions: variable, usually thousands per day
- Deployment events: low volume

Yearly total in a typical deployment: 5-50 million entries. PostgreSQL with the stated indexes handles this easily. Partitioning by `occurred_at` quarter is planned at 50M+ and is non-disruptive (native partitioning; existing queries continue to work).

Query performance targets:

- Per-node timeline (first page 50 entries): < 50ms at 50M total
- Global timeline with text search: < 500ms at 50M total
- Live update latency (ingestor → PubSub → LiveView): < 100ms end-to-end

## 7.15 Testing

Property-based tests (`TEST-203`) for event extraction:

- Synthetic Puppet reports with varying mixes of changes and noops → extractor never emits noops.
- Duplicate report ingest → no duplicate entries.
- Events from one report → all share the `group_key`.
- Monitoring transitions → one entry per transition, none for steady state.

End-to-end tests:

- Create manual note, verify it appears in per-node and global timelines.
- Submit execution, verify journal entries arrive after completion.
- Simulate monitoring transition via fixture, verify transition entry.

---

[← Previous: Execution & Streaming](06-execution-and-streaming.md) | [Next: Auth & RBAC →](08-auth-rbac.md)

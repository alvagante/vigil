# 5. Aggregation, Identity Linking, Caching, Resilience

This section realizes PRD `INV-*`, `CACHE-*`, `PERF-*`, `RES-*`, and `HEALTH-*`. These are the cross-cutting platform mechanics that make plugin data composable and keep the system responsive when individual sources misbehave.

## 5.1 Aggregation model

The platform never denormalizes a single inventory, journal, or fact set across sources. Aggregation is **per-request, streaming, deadline-bounded**.

```elixir
defmodule Vigil.Core.Inventory do
  def list_nodes(principal, filter, opts) do
    integrations = visible_integrations(principal, :inventory)
    deadline = opts[:deadline_ms] || 2_000

    tasks =
      integrations
      |> Task.Supervisor.async_stream_nolink(
        Vigil.TaskSupervisor,
        fn int -> fetch_from(int, filter, opts) end,
        max_concurrency: length(integrations),
        timeout: deadline,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    # Classify results: fresh, stale, unavailable
    {fresh, stale, unavailable} = classify(tasks, integrations)

    merged = merge_and_link(fresh ++ stale, principal)

    %AggregationResult{
      nodes: merged,
      sources_ok: fresh,
      sources_stale: stale,
      sources_unavailable: unavailable,
      partial?: unavailable != []
    }
  end
end
```

Design notes:

- `async_stream_nolink` with `timeout` enforces per-source deadlines without blocking the overall deadline (`INV-004`, `ERR-202`).
- `on_timeout: :kill_task` ensures a slow source task doesn't linger.
- Each source's `fetch_from/3` goes through `Vigil.Plugin.Dispatcher`, which consults ETS cache first and falls back to the live call (`INV-501`, `INV-505`).
- The `AggregationResult` always reports which sources contributed, which are stale, which are unavailable — the UI uses this to satisfy `INV-005` and `UI-207`.

### 5.1.1 Progressive rendering

For the LiveView pattern (`FLOW-502`), aggregation can be *streamed* into the UI rather than awaited whole:

```elixir
def progressive_list_nodes(principal, filter, opts) do
  integrations = visible_integrations(principal, :inventory)
  parent = self()

  for int <- integrations do
    Task.Supervisor.start_child(Vigil.TaskSupervisor, fn ->
      result = fetch_from(int, filter, opts)
      send(parent, {:partial_nodes, int.id, result})
    end)
  end

  # LiveView assigns partial state; handle_info({:partial_nodes, ...}) updates
end
```

The inventory LiveView receives a `{:partial_nodes, integration_id, result}` message per source as they complete. It merges into the display as each arrives. Users see fast sources first; slow sources appear when ready; unreachable sources show a marker. This is the pattern that services `FLOW-502` and `UI-207`.

The same progressive rendering pattern is used for the **journal timeline** (see [section 7](07-journal-and-events.md)). The journal fetches events from each integration's API on-demand when the user views the page, merging results into a chronologically-sorted timeline as each source responds. Local entries (executions, manual notes) render immediately from PostgreSQL; external events fill in progressively.

## 5.2 Identity linking

The linker is the single most delicate piece of domain logic. It decides whether two observations from different sources describe the same node. PRD sections 11.1.2 and 12.1.1 constrain the behaviour; this section defines the implementation.

### 5.2.1 Linker inputs

```elixir
%Vigil.Core.Inventory.Observation{
  plugin_id: "puppet",
  integration_id: "<uuid>",
  source_identity: %{certname: "web-01.prod", fqdn: "web-01.prod.example.com"},
  confidence: %{certname: :canonical, fqdn: :strong, primary_ip: :unstable},
  groups: ["webservers", "production"],
  last_seen: ~U[2026-05-06 12:00:00Z]
}
```

Confidence comes from the plugin's `identity_confidence/0` (`TYPE-INV-005`, `PUP-106`). Certname is canonical for Puppet; FQDN is strong; IP is unstable.

### 5.2.2 Linker algorithm

```
For each incoming observation:
1. Build candidate keys from its identity_attrs (certname, fqdn, hostname, primary_ip).
2. Consult the candidate index (below) to find existing nodes with matching attrs.
3. Filter candidates by applicable linking rules, in priority order.
4. Weight candidates by source confidence.
5. If exactly one candidate:
     link the observation to that node (upsert node_sources).
6. If zero candidates:
     create a new node with a fresh UUID; insert node_sources.
7. If multiple candidates:
     check manual_links for a decisive link/unlink override.
     if override present → apply it.
     if no override → record a conflict; leave the observation un-linked; raise to admin via 'unresolved links' view.
```

The candidate index is a set of Postgres indexes on JSONB paths:

```sql
-- Partial, expression-based GIN indexes for fast lookup:
CREATE INDEX nodes_certname_idx ON nodes ((identity_attrs->>'certname'))
  WHERE identity_attrs ? 'certname';
CREATE INDEX nodes_fqdn_idx ON nodes ((identity_attrs->>'fqdn'))
  WHERE identity_attrs ? 'fqdn';
CREATE INDEX nodes_hostname_idx ON nodes (lower(identity_attrs->>'hostname'))
  WHERE identity_attrs ? 'hostname';
CREATE INDEX nodes_primary_ip_idx ON nodes ((identity_attrs->>'primary_ip'))
  WHERE identity_attrs ? 'primary_ip';
```

Lookups on these indexes are O(log n). For 10,000 nodes, the full linking pass runs in under a second.

### 5.2.3 Linking rules

Rules are stored in `linking_rules`. A rule is a JSONB document:

```json
{"match": "certname", "weight": 100}
{"match": "fqdn", "weight": 50, "case_insensitive": true}
{"match": "hostname", "weight": 30, "case_insensitive": true}
{"match": "primary_ip", "weight": 10, "enabled_by_default": false}
```

Default ruleset (`INV-104`):

1. Match certname → link.
2. Else match FQDN → link.
3. Else match hostname (case-insensitive) → link.
4. Match by IP only when explicitly enabled.

Rules are immutable once created; edits create new rules with a new priority. This makes `INV-107` (manual overrides persist across rule changes) mechanically simple — overrides are decisions, rules are heuristics, and decisions always win.

### 5.2.4 Batching and full-recompute

Linking runs in two modes:

- **Per-observation (online):** Every incoming observation is linked immediately as part of the inventory refresh.
- **Full recompute (maintenance):** An admin can trigger a full re-link — e.g., after a ruleset change. This is a background Oban job that processes all `node_sources` in batches, respecting manual overrides.

For the 10,000-node target at full recompute, the batched pipeline processes ~5,000 observations per second on modest hardware. `INV-110`'s "no quadratic blowup" is satisfied by indexed lookups.

### 5.2.5 Conflict surfacing

When multiple candidates match and no manual override applies, the observation is flagged as a conflict:

```sql
CREATE TABLE link_conflicts (
  id               UUID PRIMARY KEY,
  tenant_id        UUID NOT NULL,
  observation      JSONB NOT NULL,
  candidates       JSONB NOT NULL,   -- list of candidate node_ids + reasons
  detected_at      TIMESTAMPTZ NOT NULL,
  resolved_at      TIMESTAMPTZ,
  resolution       JSONB              -- {'manual_link': <node_id>} | {'manual_unlink': 'all'}
);
```

The admin "unresolved links" view (`INV-109`) is a LiveView over this table. Resolution writes a `manual_links` row; the conflict is marked resolved.

## 5.3 Cache architecture

### 5.3.1 ETS layout

One ETS table per `{integration_id, capability}`:

```elixir
:ets.new(table_name(int_id, :inventory), [
  :set,
  :public,
  :named_table,
  read_concurrency: true,
  write_concurrency: true
])
```

Key format:

```
{action, args_hash, principal_scope_hash}
```

Value format:

```elixir
%CacheEntry{
  data: term,
  stored_at: DateTime,
  expires_at: DateTime,
  source_health_at_store: :healthy | :degraded,
  size_bytes: non_neg_integer
}
```

Per-integration table sizing is bounded by `CACHE-008`. A Janitor GenServer periodically sweeps expired entries and evicts LRU when size exceeds the budget.

### 5.3.2 Cache key scoping per principal

`CACHE-006` requires principal-scoped cache keys. The principal's scope hash is derived from its roles' target selectors that affect the capability:

```elixir
defp principal_scope_hash(principal, integration_id, capability) do
  principal
  |> Vigil.Core.RBAC.scope_filters_for(integration_id, capability)
  |> :erlang.phash2()
end
```

Users with the same effective scope share cache entries. Users with different scopes get independent cache entries. Admins with unrestricted scope hash to a distinct value.

### 5.3.3 Freshness model

Three states per entry, per `CACHE-005`:

| State | Condition | UI treatment |
|-------|-----------|--------------|
| `:live` | TTL not expired; source healthy | No marker |
| `:stale` | TTL expired or source unhealthy; cached copy still available | Staleness marker: "last fetched <t>" |
| `:unavailable` | No cached copy; source unhealthy | Source banner: "X unavailable — retry?" |

The dispatcher returns a `freshness` tag on every result. The UI renders accordingly.

### 5.3.4 Invalidation

Three invalidation paths:

- **Time-based (TTL):** default. Configured per-integration-per-capability.
- **Webhook-driven (`CACHE-004`):** Phoenix controller receives webhook, enqueues Oban job, job invalidates cache keys matching the event.
- **Manual (`CACHE-003`, `PLUG-013`):** User clicks "refresh" in the UI; dispatcher runs `flush/2` and publishes `{:cache_invalidated, integration_id, scope}` on PubSub; all interested LiveViews re-fetch.

## 5.4 Circuit breakers

Per PRD `RES-001..RES-006`, each `{integration_id, capability}` has an independent circuit breaker. Implementation options:

1. **`:fuse` library** — battle-tested Erlang library, simple API:
   ```elixir
   :fuse.install(name, {{:standard, 5, 30_000}, {:reset, 60_000}})
   ```
2. **Custom GenServer** — more control over backoff and diagnostic hooks.

We start with `:fuse` and migrate to custom only if observability shortcomings force it.

The dispatcher consults the breaker:

```elixir
case :fuse.ask(breaker_name(int_id, cap), :sync) do
  :ok ->
    execute_plugin_call(...)
  :blown ->
    {:error, %Error{category: :transient_external,
                    retriable?: true, message: "circuit breaker open"}}
end
```

On call result:

```elixir
case result do
  {:ok, _} -> :fuse.reset(breaker_name(int_id, cap))
  {:error, %{retriable?: true}} -> :fuse.melt(breaker_name(int_id, cap))
  {:error, _} -> :ok   # non-retriable errors don't melt the fuse
end
```

Configuration errors and auth failures are non-retriable — they don't trip the breaker; they raise a plugin health issue.

Recovery (`RES-004`): after cooldown, `:fuse` automatically allows probe calls. On success, the breaker resets. A recovery event is logged and a telemetry span is emitted.

## 5.5 Retry policy

Transient errors (timeouts, 5xx, rate limits) retry with exponential backoff. Configured per integration.

```elixir
defmodule Vigil.Plugin.Retry do
  @defaults %{max_attempts: 3, base_ms: 500, factor: 2, jitter: 0.2}

  def with_retry(policy \\ @defaults, fun) do
    retry_loop(policy, fun, 1)
  end

  defp retry_loop(policy, fun, attempt) do
    case fun.() do
      {:ok, _} = ok -> ok
      {:error, %{retriable?: true}} when attempt < policy.max_attempts ->
        Process.sleep(backoff(policy, attempt))
        retry_loop(policy, fun, attempt + 1)
      err -> err
    end
  end
end
```

`RES-006`: retries run *inside* the circuit breaker check. When the breaker is open, retries don't happen.

## 5.6 Health check framework

Each plugin provides `Vigil.Plugin.Health.probe/1` returning per-capability status:

```elixir
@type status :: :healthy | :degraded | :unhealthy

@type probe_result :: %{
  overall: status,
  capabilities: %{capability => %{status: status, last_success: DateTime.t(), diagnostic: String.t()}},
  checked_at: DateTime.t()
}
```

A per-integration `Health` worker runs probes at the configured interval (`HEALTH-001`, `PLUG-111`, default 30s). Probe results are:

1. Stored in memory for fast dispatcher lookup.
2. Mirrored to the `integrations.health` JSONB column (denormalized for fast dashboard render).
3. Published on PubSub topic `integration_health:<id>` for subscribers.
4. Fed into the telemetry stream for metrics.

Probes are intentionally lightweight (`HEALTH-003`, `PLUG-113`): token-validate, single-row queries, small discovery calls. Not full data fetches.

### 5.6.1 Flapping detection

Health history is kept in a ring buffer (last N samples, configurable). If the status oscillates between `:healthy` and `:unhealthy` too often, a flapping flag is raised in the status dashboard (`HEALTH-104`, `PLUG-114`).

### 5.6.2 Degraded state detection

Per-capability status allows partial degradation (`RES-203`, `ERR-101..103`):

- A plugin with `overall: :degraded` still serves capabilities marked healthy.
- The UI grays out only the affected sections.
- The dispatcher returns cached-stale for degraded capabilities and fresh for healthy ones.

## 5.7 Timeouts and deadlines

Every external call has an explicit deadline (`RES-201`). The deadline is:

- Set at the request boundary (HTTP request, LiveView assign, MCP tool call).
- Propagated through the dispatcher.
- Honored by the plugin when calling Finch / SSH / subprocess.

Deadline exhaustion returns `{:error, :deadline_exceeded}` which is reported as timeout, not error (`ERR-204`).

### 5.7.1 CLI-based integrations

Bolt, Ansible, SSH all invoke CLIs. The `Port` wrapper tracks wall-clock and idle:

```elixir
defmodule Vigil.Plugin.CLIRunner do
  def run(cmd, args, opts) do
    port = Port.open({:spawn_executable, cmd},
                     [:binary, :exit_status, :use_stdio, :stderr_to_stdout,
                      args: args])
    monitor(port, opts)
  end

  defp monitor(port, opts) do
    wall_deadline = now_ms() + opts.wall_clock_ms
    idle_deadline_ref = :erlang.start_timer(opts.idle_ms, self(), :idle_timeout)

    receive do
      {^port, {:data, chunk}} ->
        broadcast(chunk)
        :erlang.cancel_timer(idle_deadline_ref)
        monitor(port, opts)  # restart idle timer
      {^port, {:exit_status, code}} -> {:ok, code}
      {:timeout, ^idle_deadline_ref, :idle_timeout} ->
        Port.close(port); kill_orphans(port); {:error, :idle_timeout}
    after
      wall_deadline - now_ms() ->
        Port.close(port); kill_orphans(port); {:error, :wall_timeout}
    end
  end
end
```

`kill_orphans/1` sends SIGTERM then SIGKILL to any child processes of the port after the wall timeout, handling `RES-104` (ghost process detection).

## 5.8 Observability of aggregation

Telemetry events give operators visibility into per-source performance:

- `[:vigil, :aggregation, :source, :stop]` with `%{duration_ms, source_id, freshness}`.
- `[:vigil, :aggregation, :partial]` when any source times out.

Dashboards built from these events answer: which source is the slowest? Which integration times out most often? Which cache has the lowest hit rate? These feed directly into the "which integration to optimize first" decision.

## 5.9 Performance targets (consolidated)

| Target | Mechanism |
|--------|-----------|
| 10,000-node inventory in 2 seconds first-page render (`PERF-002`) | ETS cache hit + cursor pagination; aggregation runs in under 500ms cached |
| No slower-than-slowest-source latency (`EXS-002`, `NFR-007`) | Fast-sources-first progressive rendering |
| 5 concurrent users no read queueing (`PERF-007`) | Ecto pool sized for concurrency + LiveView per-process isolation |
| 100 concurrent streaming executions (`PERF-008`, `STR-101`) | Dynamic supervisor, per-execution process, no shared state |
| Request deduplication (`PERF-004`, `PUP-1004`) | Request coalescer in the dispatcher |
| Incremental updates (`PERF-009`, `STR-502`) | Plugin supports change-feed queries; dispatcher passes checkpoint |

Scale-out (multi-node) uses `libcluster` + `Phoenix.PubSub.PG` adapter for inter-node message fan-out. PostgreSQL and Oban are shared.

---

[← Previous: Data Model](04-data-model.md) | [Next: Execution & Streaming →](06-execution-and-streaming.md)

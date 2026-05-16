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

The linker is the single most delicate piece of domain logic. It decides whether two observations from different sources describe the same node. PRD sections 11.1.2 and 12.1.1 constrain the behaviour; **ADR-0003** prescribes the algorithm; this section defines the implementation.

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

### 5.2.2 The multi-attribute inverted index

`INV-110` prohibits quadratic comparison; **ADR-0003** specifies a multi-attribute inverted index maintained in memory. For each linkable attribute, a map from normalized attribute value to canonical `node_id`:

```
certname_index : normalized_string → node_id
fqdn_index     : normalized_string → node_id
hostname_index : normalized_string → node_id
ip_index       : normalized_string → node_id
```

The index is owned by `Vigil.Core.Inventory.Linker`, a single supervised process under `Vigil.Core.Supervisor` (see [§2.2](02-application-topology.md#22-top-level-supervision-tree)). Storage:

```elixir
defmodule Vigil.Core.Inventory.Linker.Index do
  # One ETS table per attribute, owned by the Linker process.
  # :set semantics; named tables; protected access (only the Linker writes).

  @tables [:linker_certname, :linker_fqdn, :linker_hostname, :linker_ip]

  def init do
    for t <- @tables do
      :ets.new(t, [:set, :named_table, :protected, read_concurrency: true])
    end
  end

  def lookup(:certname, value), do: ets_get(:linker_certname, normalize(:certname, value))
  def lookup(:fqdn,     value), do: ets_get(:linker_fqdn,     normalize(:fqdn, value))
  def lookup(:hostname, value), do: ets_get(:linker_hostname, normalize(:hostname, value))
  def lookup(:ip,       value), do: ets_get(:linker_ip,       normalize(:ip, value))

  defp normalize(:certname, v), do: String.downcase(v)
  defp normalize(:fqdn,     v), do: v |> String.downcase() |> String.trim_trailing(".")
  defp normalize(:hostname, v), do: String.downcase(v)
  defp normalize(:ip,       v), do: canonicalize_ip(v)   # :inet.parse_address → back to string
end
```

ETS tables hold the live index; the Linker GenServer is the single writer. The tables are `:protected` so any process can read for fast lookups without GenServer round-trips, but only the Linker mutates them — preserving consistency under concurrent integration cache refresh callbacks.

### 5.2.3 Linker algorithm

For each incoming observation from an integration cache refresh:

```
1. Walk the attribute cascade (certname → fqdn → hostname → ip,
   subject to per-rule enable flags and source confidence).
2. For each present attribute, point-lookup the corresponding ETS table.
3. Collect the set of node_ids returned. Three cases:

   (a) Empty set:
       Create a new canonical node row (Vigil.Core.Nodes.insert/1),
       insert all attribute → node_id entries into the index,
       upsert node_sources for this (node_id, integration_id).

   (b) One node_id:
       Upsert node_sources; add any new attribute claims from this
       observation to the index under the existing node_id.

   (c) Multiple distinct node_ids:
       Check manual_links for a decisive link/unlink override.
       If override → apply it.
       Otherwise → write a link_conflicts row; do NOT link.
```

Each step is a point operation: ETS `:ets.lookup/2` is O(1); the Postgres upsert is keyed by `(node_id, integration_id)` with a unique index. Linking an incoming batch of M records costs O(M × A) where A = 4 (the cascade depth) — linear, independent of total inventory size N. `INV-110` is satisfied.

### 5.2.4 Incremental update on cache refresh

The integration cache layer (see [§5.3](#53-cache-architecture)) publishes `{:integration_cache_refreshed, integration_id, observations}` on PubSub when a refresh completes. The Linker subscribes on startup:

```elixir
defmodule Vigil.Core.Inventory.Linker do
  use GenServer

  def init(_opts) do
    Index.init()
    rebuild_from_db()       # see §5.2.6
    Phoenix.PubSub.subscribe(Vigil.PubSub, "inventory:cache_refreshed")
    {:ok, %{}}
  end

  def handle_info({:integration_cache_refreshed, integration_id, observations}, state) do
    Enum.each(observations, &link_one(&1, integration_id))
    detect_unreported(integration_id, observations)   # see §5.2.5
    {:noreply, state}
  end

  def handle_call({:decommission, node_id, principal}, _from, state) do
    release_claims(node_id)
    {:reply, :ok, state}
  end
end
```

The linker never scans the full inventory. Each refresh costs O(refresh_size), never O(total_nodes). Refreshes from different integrations are serialized by the GenServer's mailbox — index mutations are interleaved at message boundaries, never partially observed.

### 5.2.5 Detecting the Unreported transition (DM-1109)

After each integration cache refresh, the Linker compares the set of node_ids the integration *previously* reported with the set in the current refresh:

```elixir
defp detect_unreported(integration_id, current_observations) do
  current_ids   = MapSet.new(current_observations, & &1.node_id)
  previous_ids  = Vigil.Core.Nodes.ids_currently_attributed_to(integration_id)
  dropped_ids   = MapSet.difference(previous_ids, current_ids)

  for node_id <- dropped_ids do
    case Vigil.Core.Nodes.remove_source(node_id, integration_id) do
      {:ok, %{remaining_sources: 0}} ->
        # No integration reports this node any more.
        Vigil.Core.Nodes.transition_lifecycle(node_id, :unreported)
      {:ok, _} ->
        # Still reported by at least one other integration; lifecycle unchanged.
        :ok
    end
  end
end
```

`Unreported` is a derived signal — a node stays `Active` as long as any integration reports it (`DM-1101a`). Transitions to `Decommissioned` are *only* triggered by explicit admin action via `decommission/2`.

### 5.2.6 Startup rebuild

`ADR-0003`: the index is reconstructed at startup from persisted identity records. The Linker's `init/1` runs `rebuild_from_db/0` synchronously before subscribing to refresh events:

```elixir
defp rebuild_from_db do
  Vigil.Core.Nodes.stream_active_and_unreported()
  |> Enum.each(fn node ->
    for {attr, value} <- node.identity_attrs, attr in [:certname, :fqdn, :hostname, :ip] do
      Index.put(attr, value, node.id)
    end
  end)
end
```

`Decommissioned` nodes are deliberately excluded — their identity claims have been released (`DM-1107`). At 10,000 nodes × 4 attributes, the rebuild is ~40,000 ETS inserts: well under one second on commodity hardware. The index is never persisted; PostgreSQL is the durable substrate, ETS is the lookup substrate.

### 5.2.7 Decommission releases identity claims

When an administrator decommissions a node (`DM-1106`), the Linker erases all attribute claims attributed to that `node_id` so that a future node reported at the same address links fresh (`DM-1107`):

```elixir
defp release_claims(node_id) do
  for t <- [:linker_certname, :linker_fqdn, :linker_hostname, :linker_ip] do
    :ets.match_delete(t, {:_, node_id})
  end
end
```

`:ets.match_delete/2` scans the table but the operation is bounded by table size, which is bounded by the index attribute count × 10,000 nodes (= ~40,000 entries). At this size, the operation completes in milliseconds. The Linker holds a write lock on the index for the duration via its GenServer mailbox, so concurrent refreshes serialize behind the decommission.

After release, the lifecycle state is set to `:decommissioned` (see [§4.3.1](04-data-model.md#431-nodes--canonical-node-records)) and the identity attributes are retained on the row for historical journal references.

### 5.2.8 Linking rules

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

Rule changes do not invalidate the in-memory index — the index records *which node_id claims which value*, not *why*. A rule change only affects what new observations are allowed to claim against. An optional admin-triggered "rebuild index" pass (a one-shot GenServer call) is the way to re-evaluate existing identity records against a changed ruleset.

### 5.2.9 Batching and full-recompute

Linking runs in two modes:

- **Per-observation (online):** Every incoming observation in an integration cache refresh is point-looked-up and linked immediately, in the Linker's GenServer mailbox order.
- **Full recompute (maintenance):** An admin can trigger a full re-link after a ruleset change. This is a background Oban job in the `maintenance` queue that streams all persisted identity records, clears the index, and rebuilds it observation-by-observation. Manual overrides are applied last so they always win.

At the 10,000-node target, a full recompute runs in seconds; the platform stays serving via cached data, since the index is still queryable mid-rebuild — the Linker holds a "rebuild in progress" flag and writes to a shadow set of ETS tables that are atomically swapped at the end.

### 5.2.10 Conflict surfacing

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

`CACHE-006` (revised) and [ADR-0006](../../adr/0006-shared-unfiltered-integration-cache.md) prescribe a **shared, unfiltered integration cache**. The cache holds the full integration response keyed by integration + capability; RBAC target-scope filtering is applied at *presentation time*, after the cache lookup and before the response leaves the application layer. Cache entries are shared across all users who have access to the integration; per-principal cache entries are not used.

This inverts the earlier per-principal-scoped design. The justification: at the 10,000-node target, filtering a single full inventory against a compiled effective scope is cheaper than maintaining one cache entry per principal, which multiplies memory use and cache misses by the number of distinct permission scopes in the deployment.

### 5.3.1 ETS layout

One ETS table per `{integration_id, capability}`:

```elixir
:ets.new(table_name(int_id, :inventory), [
  :set,
  :protected,
  :named_table,
  read_concurrency: true,
  write_concurrency: true
])
```

Key format:

```
{action, args_hash}
```

`args_hash` covers the non-principal arguments to the capability call (filter parameters, since-cursor, etc.). It does **not** include any principal identity — that is the structural difference from the previous design.

Value format:

```elixir
%CacheEntry{
  data: term,                          # FULL unfiltered integration response
  source_attribution: %{...},          # plugin_id + integration_id for every record
  stored_at: DateTime,
  expires_at: DateTime,
  source_health_at_store: :healthy | :degraded,
  size_bytes: non_neg_integer
}
```

Per-integration table sizing is bounded by `CACHE-008` and must accommodate the full integration inventory, not paginated slices — pagination is applied *after* RBAC filtering at presentation time. A Janitor GenServer periodically sweeps expired entries and evicts LRU when size exceeds the budget.

### 5.3.2 Presentation-time RBAC filtering

The dispatcher returns the unfiltered `%CacheEntry{}` to the application layer. The application layer applies the principal's target-scope filter before serializing the response:

```elixir
defmodule Vigil.Core.Inventory do
  def list_nodes(%Scope{} = scope, filter, opts) do
    integrations = visible_integrations(scope, :inventory)

    integrations
    |> aggregate_unfiltered(filter, opts)               # cache hits return full data
    |> Vigil.Core.RBAC.filter_targets(scope, :nodes)    # apply per-principal target scope
    |> apply_user_filter(filter)
    |> paginate(opts.cursor, opts.page_size)
  end
end
```

`Vigil.Core.RBAC.filter_targets/3` resolves the principal's effective target selectors once (cached in the per-process `Scope` for the request's lifetime) and runs the in-memory predicate over the result set. The filter path operates on normalized attributes already present on cached records: integration id, node id, group id, environment, site, tenant, tags, and source-specific target identifiers.

The important performance invariant is that cache-hit filtering is `records x cheap predicate`, not `records x RBAC rules`. Raw role/rule interpretation happens when building the effective scope, not once per cached object. See [§8.3](08-auth-rbac.md) for the target-scope evaluation algorithm — `RBAC-108` requires the per-target evaluation to be a constant number of data-store queries, which the presentation-time filter satisfies by issuing bounded queries to resolve the principal's scope and zero queries during the in-memory filter.

If a deployment adds enough granular RBAC that a linear scan over cached records becomes measurable, the next step is not per-principal cache keys. The cache remains shared and unfiltered, while the application layer adds derived indexes such as `%{environment_id => records}`, `%{site_id => records}`, `%{node_group_id => records}`, or scoped materialized subsets invalidated with the parent cache entry.

> **Decision: Cache stores integration truth; the application layer enforces visibility.**
> Two consequences worth surfacing:
> 1. Two users with different scopes hit the same ETS entry — the cache hit rate is now per-integration, not per-principal. At the target deployment scale this is a meaningful win.
> 2. The cache must hold the full integration inventory. Capability calls that the plugin paginates server-side must be unpaginated on entry to the cache (the cache stores the *whole* result set assembled from cursors), so that presentation-time filtering operates against the same universe regardless of which user fetched first.

### 5.3.3 Pagination is post-filter

Because the cache holds full results, pagination is a *post-filter* concern. The application layer computes the filtered, sorted result, then applies cursor-based pagination on the filtered output. Users with narrower scopes see fewer pages, not fewer items per page — which is the right behaviour for "the user restricted to web-servers should not see other nodes anywhere in inventory" (`RBAC-107`).

A LiveView paginating through filtered output does not re-issue the cache lookup per page — the application layer holds the filtered, sorted list in the LiveView's assigns and slices it per page transition. The cache is consulted only when the integration data is stale (TTL expiry) or the filter parameters change.

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

> **Decision: The per-integration GenServer health worker is the canonical liveness probe mechanism. Oban is used for maintenance tasks only.**
> `HEALTH-005` requires a single owner for continuous per-integration probing. The per-integration `Health` GenServer is that owner — it holds the tick timer, the ring-buffer history, and the per-capability probe logic. The Oban `maintenance` queue (noted in design/02 §2.3 and design/12 §12.2) is reserved for lower-frequency work with retention, recomputation, or snapshot semantics (e.g., 24h-scale cache cleanup, weekly retention enforcement, cold-start warmer bootstrap). Oban **MUST NOT** schedule health-probe jobs of the same cadence as the GenServer ticker — that would produce double-firing against integrations already under health-probe load. The `maintenance` queue's minimum frequency for any job is `60s`, and no maintenance job's purpose overlaps with live health probing.

### 5.6.1 Flapping detection (HEALTH-104/105)

`HEALTH-104` defines flapping as **3 or more healthy↔unhealthy transitions within a rolling 30-minute window** (both thresholds configurable). `HEALTH-105` defines the four-state model the dashboard renders.

The per-integration `Health` GenServer owns the state machine. Two pieces of state are added beyond the simple ring buffer:

```elixir
defmodule Vigil.Integrations.Health.State do
  defstruct integration_id: nil,
            current: :unknown,           # :healthy | :degraded | :unhealthy | :flapping
            last_probe_status: :unknown, # :healthy | :degraded | :unhealthy
            # Sliding window of timestamps of healthy↔unhealthy transitions only.
            # Degraded↔healthy and degraded↔unhealthy are NOT counted — flapping is
            # defined against the binary healthy/unhealthy axis per HEALTH-104.
            transitions: :queue.new(),
            window_ms: 30 * 60 * 1000,
            flap_threshold: 3,
            capabilities: %{}             # per-capability status from the probe
end
```

On each probe result:

```elixir
def handle_info(:probe, state) do
  result = run_probe(state.integration_id)             # {:healthy | :degraded | :unhealthy, caps}

  new_status     = headline_status(result)              # collapse capability map to one
  is_transition? = transition_on_binary_axis?(state.last_probe_status, new_status)

  transitions =
    if is_transition?,
      do: :queue.in(monotonic_now_ms(), state.transitions),
      else: state.transitions

  transitions = trim_outside_window(transitions, state.window_ms)
  flap_count  = :queue.len(transitions)
  flapping?   = flap_count >= state.flap_threshold

  current =
    cond do
      flapping?                   -> :flapping
      new_status == :degraded     -> :degraded
      new_status == :unhealthy    -> :unhealthy
      true                        -> :healthy
    end

  emit_telemetry(state.integration_id, current, flap_count)
  publish_health(state.integration_id, current, result.capabilities, flap_count)
  schedule_next_probe()

  {:noreply, %{state | current: current,
                       last_probe_status: new_status,
                       transitions: transitions,
                       capabilities: result.capabilities}}
end

defp transition_on_binary_axis?(:healthy, :unhealthy), do: true
defp transition_on_binary_axis?(:unhealthy, :healthy), do: true
defp transition_on_binary_axis?(_, _),                 do: false
```

The key design choices:

- **Erlang `:queue` over a fixed-size ring buffer.** The window is *time-based* (30 min), not count-based. Storing only transition *timestamps* (not every probe result) bounds memory at `flap_count` integers — ~3-10 timestamps in practice. A naive "store every probe sample" approach would carry 60 entries (one every 30 s × 30 min) per integration with no semantic gain.
- **`trim_outside_window/2` is O(transitions_in_queue).** It dequeues entries older than `now - window_ms` from the front. Since the queue length is bounded by the flap threshold under steady-state flapping (older transitions trim before new ones arrive), each tick costs O(1) amortised.
- **Flapping is binary axis only.** A degraded↔healthy oscillation is *not* flapping — it is intermittent degradation, surfaced via the degraded state and the per-capability detail panel (`HEALTH-105`). This matches `HEALTH-104`'s prose: "three or more healthy↔unhealthy transitions."
- **The four-state aggregation is a `cond` in priority order.** `flapping` wins over `unhealthy` wins over `degraded` wins over `healthy`. This is the order the dashboard card needs (`HEALTH-105`).

The published health payload on `integration_health:<id>` carries `{current, capabilities, flap_count}` so the dashboard card can render the headline status, the per-capability detail panel, and the "N state changes in the last 30 min" flap indicator (`HEALTH-105` requirement (c)) without any further query.

When flapping resolves — the queue trims below the threshold during a stable period — the state transitions back to whatever the latest probe says (`:healthy`, `:degraded`, or `:unhealthy`) and a `health.flapping_resolved` telemetry event is emitted for alerting integrations.

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
| 10 concurrent users no read queueing (`PERF-007`) | Ecto pool sized for concurrency + LiveView per-process isolation |
| 100 concurrent streaming executions (`PERF-008`, `STR-101`) | Dynamic supervisor, per-execution process, no shared state |
| Request deduplication (`PERF-004`, `PUP-1004`) | Request coalescer in the dispatcher |
| Incremental updates (`PERF-009`, `STR-502`) | Plugin supports change-feed queries; dispatcher passes checkpoint |

Scale-out (multi-node) uses `libcluster` + `Phoenix.PubSub.PG` adapter for inter-node message fan-out. PostgreSQL and Oban are shared. HA — the libcluster integration itself, distributed PubSub beyond in-node, and session affinity — is delivered by `vigil_enterprise` (FS EE-2); CE ships the single-node topology.

## 5.10 Cold-start cache warming

`CACHE-009` requires that the platform warm high-priority caches after startup so users don't hit empty-cache latency after every deploy. The justification: `PUP-1001` sets a 15-minute inventory TTL; a naive cold start leaves the inventory page slow for the full TTL as each capability misses and back-pressures PuppetDB.

### 5.10.1 Warming trigger

On application startup, after all integrations have completed their first health probe, `Vigil.Core.Cache.Warmer` inspects each integration's `warm_on_boot` configuration and enqueues one Oban job per `{integration_id, capability}` into the `maintenance` queue. Oban's SKIP LOCKED ensures each job runs exactly once across a cluster.

```elixir
defmodule Vigil.Core.Cache.Warmer do
  use GenServer

  def init(_) do
    Phoenix.PubSub.subscribe(Vigil.PubSub, "integration_health:all")
    # Delay first pass until all integrations have reported at least once
    Process.send_after(self(), :first_warm_pass, 10_000)
    {:ok, %{warmed: MapSet.new()}}
  end

  def handle_info(:first_warm_pass, state) do
    for int <- healthy_integrations() do
      enqueue_warm_jobs(int)
    end
    {:noreply, %{state | warmed: MapSet.new(Enum.map(healthy_integrations(), & &1.id))}}
  end

  def handle_info({:health, int_id, :healthy, _caps, _diag}, state) do
    # Warm a newly-healthy integration that wasn't warmed on boot
    unless MapSet.member?(state.warmed, int_id) do
      enqueue_warm_jobs(int_id)
    end
    {:noreply, %{state | warmed: MapSet.put(state.warmed, int_id)}}
  end

  defp enqueue_warm_jobs(int) do
    for cap <- warmable_capabilities(int), into: [] do
      %{integration_id: int.id, capability: cap}
      |> Vigil.Oban.Workers.CacheWarmer.new(priority: warm_priority(cap),
                                             queue: :maintenance)
      |> Oban.insert()
    end
  end

  defp warm_priority(:inventory), do: 0      # highest
  defp warm_priority(:facts),     do: 1
  defp warm_priority(:reports),   do: 2
  defp warm_priority(_),          do: 3
end
```

### 5.10.2 Warmer worker

The worker runs inside the per-integration concurrency budget (not outside it) so background warming does not exhaust the budget that real user requests need:

```elixir
defmodule Vigil.Oban.Workers.CacheWarmer do
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"integration_id" => int_id, "capability" => cap}}) do
    # Respect the integration's concurrency limit. Warmer jobs yield to
    # user-initiated calls by taking a lower slot allocation.
    Vigil.Plugin.Dispatcher.warm(int_id, String.to_existing_atom(cap),
                                 max_concurrency_share: 0.5)
  end
end
```

`Dispatcher.warm/3` issues the same capability call a user would issue, but:

- Reserves at most half the integration's concurrency budget for warm jobs (`max_concurrency_share`). Real user requests continue to flow.
- Skips the request coalescer — warm calls do not "steal" a cache entry from a concurrent user request; they fill the cache fresh.
- Tags the telemetry span with `source: :warmer` so metrics can distinguish warm-up traffic from user traffic.

### 5.10.3 What gets warmed

Configurable per integration via `warm_on_boot: [:inventory, :facts]` (the default). Other capabilities are not warmed — the first user access pays cache-miss latency. Large facts sweeps would be disproportionate to their value; warming is deliberately conservative.

For facts specifically, warming fetches only the top-level node list with compact metadata — not full per-node fact payloads. Full facts warm lazily on first node-detail view.

### 5.10.4 Why not snapshot-to-disk

An alternative approach — persist cache state to PostgreSQL on graceful shutdown, restore on boot — was considered and rejected:

- Snapshot staleness across a long outage creates confidence-in-cache problems that the freshness tags already solve poorly.
- Restore timing (at startup) races with integration health probes; serving cached data before the first probe is misleading.
- Warming from the source tool is the canonical recovery path (`CACHE-010`); snapshots would be an optimisation layer over that, not a replacement.

Warming jobs typically complete in well under the TTL window. At 10,000 PuppetDB nodes and a healthy PuppetDB, inventory warm-up takes ~1 second. The "slow deploy" window becomes negligible.

## 5.11 Multi-node cache locality

`PERF-010` acknowledges that ETS caches are per-node in multi-node deployments. This has different implications per surface:

### 5.11.1 LiveView (solved by stickiness)

Phoenix LiveView holds a long-lived WebSocket. In a multi-node deployment, the load balancer must be configured with WebSocket stickiness (keyed on the session cookie) so each client's LiveView process stays on one node for the connection duration. This is the standard Phoenix deployment guidance and is already noted in [§12](12-deployment-and-ops.md). Cache locality follows naturally: a user's repeat queries all land on one node's ETS, giving the expected hit rate.

### 5.11.2 REST / MCP API (documented tradeoff)

The REST API and MCP endpoint are stateless HTTP. A client's repeated requests may route to any node. With N nodes and per-node ETS caches, the effective cache hit rate for a given principal degrades roughly as `1/N` compared to a single-node deployment — the principal's first request warms node A's cache; the second request lands on node B and misses; and so on.

For the 10-user target scale on a single node (the default deployment), this is moot. For multi-node deployments (an EE feature via FS EE-2), two options:

1. **Load-balancer affinity on principal identity.** Configure the load balancer to hash on the `Authorization: Bearer <token>` header so each API principal's requests route to the same node. This is straightforward in most load balancers (HAProxy `balance hdr(Authorization)`, nginx `ip_hash`-equivalent on a custom variable, AWS ALB target-group stickiness).
   - Pro: preserves single-node cache hit rates for the most common case (an AI agent issuing many queries against the MCP endpoint).
   - Con: requires load-balancer configuration, which is outside Vigil's control. Vigil documents the recommendation; operators implement it.

2. **Accept reduced hit rates.** For small clusters (2-3 nodes) and mostly-unique-principal workloads, the effective hit rate is still high enough for the 2-second page-load target. Cache locality loss is offset by distributed request handling.

The platform does **not** ship an inter-node cache (e.g., Redis, distributed ETS replication). This is deliberate:

- PostgreSQL-only is the stated stack principle.
- Introducing a distributed cache adds operational overhead disproportionate to the UX win at the target scale.
- EE FS EE-2 (HA) delivers libcluster and distributed PubSub; adding distributed cache state on top is a further scope expansion not currently justified.

### 5.11.3 Documentation obligation

The operations guide (design/12 §12.6) documents the multi-node cache behaviour and the affinity recommendation explicitly. CE's single-node default sidesteps the concern entirely.

---

[← Previous: Data Model](04-data-model.md) | [Next: Execution & Streaming →](06-execution-and-streaming.md)

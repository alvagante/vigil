# 2. Application Topology & Supervision

This section specifies the OTP supervision tree: how processes are organized, what restarts what, and where the fault boundaries sit. The topology is the backbone on which everything else hangs — plugin isolation (`PLUG-401`), graceful degradation (`ERR-001`), per-integration resource budgets (`PLUG-402`), and concurrent-user targets (`PERF-007`) all derive from it.

## 2.1 Umbrella layout

```
vigil/                                # umbrella root (CE, AGPL v3)
├── apps/
│   ├── vigil_core/                   # domain logic, Ecto, PubSub topics
│   ├── vigil_plugin/                 # plugin contract, dispatcher, conformance
│   ├── vigil_web/                    # Phoenix, LiveView, API, MCP HTTP
│   ├── vigil_auth_oidc/              # CE OIDC provider (single-IdP, literal
│   │                                 #   group-to-role mapping). Implements
│   │                                 #   the Vigil.Auth.Provider behaviour.
│   ├── vigil_integrations_puppet/
│   ├── vigil_integrations_bolt/
│   ├── vigil_integrations_ansible/
│   ├── vigil_integrations_ssh/
│   ├── vigil_integrations_proxmox/
│   ├── vigil_integrations_aws/
│   └── vigil_integrations_azure/
├── config/                           # shared config
│   ├── config.exs
│   ├── dev.exs
│   ├── test.exs
│   ├── prod.exs
│   └── runtime.exs                   # loaded at release boot
├── mix.exs                           # umbrella
└── rel/                              # mix release config
    └── vmargs.eex
```

Each umbrella child has its own `mix.exs`, its own `application/0`, and its own dependencies. The root `mix.exs` declares no runtime dependencies beyond the umbrella children.

Enterprise Edition apps (`vigil_auth_saml`, `vigil_auth_ldap`, `vigil_auth_enterprise`, `vigil_enterprise_*`) live in a separate private umbrella and are **not** present in this repository. They register into CE's extension points (`Vigil.Auth.Provider`, `Vigil.Audit.Exporter`, `Vigil.Cluster.Backend`, etc.) at runtime when the `vigil_enterprise` OTP app is loaded alongside CE. See [`docs/specs/editions.md`](../editions.md) §4 for the full EE app inventory and license-validation approach.

## 2.2 Top-level supervision tree

```
Vigil.Application
│
├── Vigil.Repo                               # Ecto Postgres repo
├── Oban                                     # background jobs, cron
├── Phoenix.PubSub (Vigil.PubSub)            # in-node PubSub
├── Finch                                    # HTTP connection pools
├── Vigil.Telemetry.Supervisor               # telemetry reporter, metrics
├── Vigil.Core.Supervisor                    # domain services
│   ├── Vigil.Core.Inventory.Linker           # identity linking worker pool
│   ├── Vigil.Core.Execution.Supervisor       # execution streams (DynamicSupervisor)
│   ├── Vigil.Core.Cache                      # ETS cache server
│   ├── Vigil.Core.Cache.Janitor              # TTL sweeper
│   ├── Vigil.Core.RBAC.PermissionCache       # compiled permission lookups
│   └── Vigil.Core.Audit.Writer               # audit trail writer
├── Vigil.Plugin.Registry                    # Registry for plugin lookup
├── Vigil.Integrations.Supervisor            # DynamicSupervisor for plugins
│   ├── Vigil.Integrations.Puppet.Supervisor.<id>    # one per configured integration
│   ├── Vigil.Integrations.Bolt.Supervisor.<id>
│   ├── ... etc
└── VigilWeb.Endpoint                        # Phoenix endpoint (last to start)
```

### 2.2.1 Startup order

Order matters. `VigilWeb.Endpoint` starts *last* so the application can start taking user traffic only when the domain, plugins, and integrations are initialized. This is particularly important for the integration status dashboard and the "no integrations" empty state (`ERR-801`).

1. `Vigil.Repo` — open the database.
2. `Oban` — start job queue (cron jobs are not triggered until all queues are up).
3. `Phoenix.PubSub` — establish pub/sub before anyone publishes.
4. `Finch` — initialize connection pools.
5. `Vigil.Telemetry.Supervisor` — install reporters before any spans.
6. `Vigil.Core.Supervisor` — domain workers.
7. `Vigil.Plugin.Registry` — plugin lookup registry.
8. `Vigil.Integrations.Supervisor` — spawn supervisors for each configured, enabled integration (from database config).
9. `VigilWeb.Endpoint` — accept HTTP/WS.

### 2.2.2 Restart strategy

| Supervisor | Strategy | Rationale |
|------------|---------|-----------|
| `Vigil.Application` (top) | `:one_for_one` | Unrelated failures don't cascade |
| `Vigil.Core.Supervisor` | `:rest_for_one` | Downstream services depend on upstream (Cache before Journal) |
| `Vigil.Integrations.Supervisor` | `:one_for_one` | Per-integration isolation (`PLUG-401`) |
| `Vigil.Integrations.<Plugin>.Supervisor.<id>` | `:one_for_one` | Per-sub-system isolation within a plugin (Puppet's PuppetDB/Puppetserver/Hiera) |
| `Vigil.Core.Execution.Supervisor` | `:one_for_one` via DynamicSupervisor | Execution streams are independent |

Restart intensity defaults to `max_restarts: 3, max_seconds: 5`. Integration supervisors carry `max_restarts: 10, max_seconds: 60` because transient external-tool errors should not escalate a plugin into quarantine prematurely — the circuit breaker handles that separately.

## 2.3 Per-integration supervision tree

Each configured integration instance gets its own supervised subtree. The example below is for Puppet; other plugins follow the same pattern with plugin-specific children.

```
Vigil.Integrations.Puppet.Supervisor.<integration_id>
│
├── Vigil.Integrations.Puppet.ConfigServer
│   # holds current configuration, validates on reload
│
├── Vigil.Integrations.Puppet.Health
│   # periodic health check, updates PubSub topic "integration_health:<id>"
│
├── Vigil.Integrations.Puppet.PuppetDB.Client
│   # Finch-backed, circuit-breakered HTTP client
│
├── Vigil.Integrations.Puppet.Puppetserver.Client
│   # Same, for Puppetserver
│
├── Vigil.Integrations.Puppet.Hiera.Reader
│   # local file reader over configured control_repo.path
│
├── Vigil.Integrations.Puppet.CircuitBreaker.Supervisor
│   ├── ... :fuse instances per sub-system
│
├── Vigil.Integrations.Puppet.ConcurrencyLimiter
│   # tracks in-flight calls, applies per-integration resource budget
│
└── Vigil.Integrations.Puppet.RequestCoalescer
    # request deduplication (`EXEC-005`, `PUP-1004`)
```

The integration's top supervisor registers itself with `Vigil.Plugin.Registry` under `{:integration, integration_id}`. The dispatcher finds it by that key when a capability call comes in.

> **Decision: One supervisor tree per integration instance, not per plugin type.**
> `DM-103` allows a single plugin to be instantiated multiple times (e.g., two AWS accounts). Each instance needs its own configuration, its own health tracking, its own circuit breaker, its own connection pool. Sharing the plugin's top-level supervisor across instances would couple their failure domains. Per-instance supervision keeps them isolated.

## 2.4 Plugin lifecycle in the tree

The plugin behaviour is specified in [section 3](03-plugin-framework.md); here is what it means for the process tree:

1. **Enable.** Admin enables an integration via the UI. `Vigil.Core.IntegrationConfig` persists the config and publishes `{:integration_enabled, integration_id}`.
2. **Spawn.** `Vigil.Integrations.Supervisor` receives the event and starts the plugin's top supervisor via `start_child/2`. The plugin module's `child_spec/1` returns the subtree.
3. **Initialize.** The plugin's `ConfigServer` reads config, the `Health` worker performs an initial health probe; results are published on the health topic.
4. **Ready.** The integration appears in the status dashboard as "starting" until the first health check completes, then "healthy" or an error state.
5. **Disable.** Admin disables. `Vigil.Integrations.Supervisor` calls `terminate_child/2`. In-flight requests are terminated per `PLUG-132`; the plugin's `shutdown` hook runs (bounded by a configurable timeout).
6. **Reload.** Admin updates configuration. `ConfigServer` receives `{:reload, new_config}` and either hot-updates (for safe fields like TTLs) or requests a supervisor restart (for connection-affecting fields).

## 2.5 Execution process lifecycle

Long-running operations (executions, provisioning, streams) have their own process tree.

```
Vigil.Core.Execution.Supervisor  (DynamicSupervisor)
│
├── Vigil.Core.Execution.Stream.<execution_id>
│   # GenServer owning the subprocess / HTTP long-poll
│   # buffers output, broadcasts chunks, persists transcript on end
│
├── Vigil.Core.Execution.Stream.<execution_id>
...
```

A LiveView user opens the execution page. The LiveView's `mount/3`:

1. Looks up or starts `Vigil.Core.Execution.Stream.<execution_id>` (via a registered name).
2. `Phoenix.PubSub.subscribe(Vigil.PubSub, "execution_stream:<id>")`.
3. Requests the current buffer contents to backfill already-produced output (`STR-103`).
4. Receives `{:execution_chunk, chunk}` messages thereafter.

If the LiveView disconnects, the `Stream` GenServer continues unaffected (`STR-203`). A re-connecting LiveView re-subscribes and backfills from the buffer. On execution completion, the GenServer writes the full transcript to Postgres and terminates gracefully after a grace period (allowing late reconnections to still get `{:execution_ended, exit_status}`).

## 2.6 Phoenix.PubSub topics

PubSub is the primary cross-process eventing channel. Topics and their payloads are part of the application's internal contract.

| Topic | Publisher | Subscribers | Payload |
|-------|-----------|-------------|---------|
| `integration_health:<id>` | Plugin health worker | Status dashboard, admin LiveViews | `{:health, status, capabilities, diagnostic}` |
| `integration_health:all` | Plugin health worker | Metrics collector | Rollup events |
| `inventory_changed:<integration_id>` | Plugin inventory refresh | Inventory LiveView, linker | `{:inventory_changed, :full | :partial, changed_ids}` |
| `node:<node_id>` | Execution stream | Node detail LiveView | `{:fact_update, diff}` |
| `execution_stream:<id>` | Execution stream GenServer | Execution LiveView, audit | `{:chunk, stream, text}`, `{:ended, status}` |
| `provisioning:<op_id>` | Provisioning tracker | Provisioning LiveView | `{:state, new_state}`, `{:ended, result}` |
| `cache_invalidated:<integration_id>` | Cache invalidator | Cache, affected LiveViews | `{:invalidate, keys}` |
| `user_session:<user_id>` | Auth controller | All user LiveViews | `{:logout}` (cross-tab, `STR-1003`) |

Topics carry the integration ID or node ID so a LiveView can subscribe to only the slice it cares about. A per-user topic supports cross-tab events like logout.

## 2.7 Telemetry and metrics

Telemetry events name the surface:

| Event | When emitted | Measurements | Metadata |
|-------|-------------|--------------|----------|
| `[:vigil, :plugin, :call, :start | :stop | :exception]` | Wrapping every plugin capability call | `:duration`, `:queue_time` | `:plugin`, `:capability`, `:integration_id`, `:result` |
| `[:vigil, :cache, :hit | :miss | :evict]` | Cache ops | `:size` | `:integration_id`, `:capability`, `:key_kind` |
| `[:vigil, :integration, :health_check]` | Health probe | `:duration`, `:ok?` | `:plugin`, `:capability`, `:integration_id` |
| `[:vigil, :execution, :started | :chunk | :ended]` | Execution stream events | `:bytes` | `:execution_id`, `:integration_id`, `:user_id` |
| `[:vigil, :http, :request :stop]` | Finch requests | `:duration`, `:status` | `:host`, `:method` |
| `[:vigil, :repo, :query]` | Ecto query | `:duration`, `:decode_time` | `:source`, `:result` |
| `[:vigil, :rbac, :check]` | Permission check | `:duration` | `:user_id`, `:action`, `:outcome` |
| `[:vigil, :aggregation, :partial]` | Inventory aggregation timed out for a source | — | `:missing_source_ids`, `:total_sources` |

These feed `TelemetryMetricsPrometheus` for the `/metrics` endpoint used by external monitoring. `HEALTH-201`, `HEALTH-202`, and `NFR-1001`, `NFR-1002` are satisfied by the telemetry layer.

Logs are structured JSON with correlation IDs per request, propagated via `Logger.metadata/1`. `NFR-1004` (no secrets in logs) is enforced by a `Logger` filter that inspects metadata against a denylist of known-secret keys (token, password, private_key, etc.).

## 2.8 Concurrency primitives

| Concern | Primitive | Notes |
|---------|-----------|-------|
| Plugin capability calls | `Task.Supervisor` with max concurrency | `PLUG-402`, `PLUG-404` |
| Aggregation across sources | `Task.async_stream/3` with `max_concurrency` + `timeout` | Fast-source-first rendering per `INV-004` |
| User request concurrency | Bandit/Cowboy acceptor pool sized > concurrent target | `PERF-007` |
| Background jobs | Oban per-queue concurrency limits | Configurable |
| Execution streams | `DynamicSupervisor` with no hard cap; soft cap per integration via `ConcurrencyLimiter` | `PERF-008`, `EXEC-301` |
| Database connections | Ecto pool (via `DBConnection`) | Sized for concurrent users + background |

A per-integration `ConcurrencyLimiter` is a `GenServer` that uses a counter and a FIFO queue. Callers check out via `ConcurrencyLimiter.call/3`; if the counter is at max, they're queued for up to a configured wait; on timeout they get `{:error, :overloaded}`. This pattern serves `EXEC-301` (three-scope concurrency: global, per-integration, per-user).

## 2.9 Multi-node posture

The initial release runs on a single BEAM node. The topology supports horizontal scaling without redesign:

- `Phoenix.PubSub` can be configured with a `PG` or `Redis` adapter for cross-node messaging.
- Plugin integrations can be pinned to specific nodes (via `libcluster` + conditional startup) so a heavy PuppetDB integration doesn't share resources with a heavy AWS one.
- PostgreSQL is shared.
- Oban's job queue is shared via Postgres, giving cross-node work distribution for free.

`NFR-105` (support rolling upgrade design) is met: two nodes running different versions can coexist for a deploy window as long as the plugin contract version is compatible. See [section 12](12-deployment-and-ops.md).

## 2.10 Failure modes and recovery

| Failure | Detection | Recovery |
|---------|-----------|----------|
| Plugin call raises | Telemetry `:exception` event | Circuit breaker increments; caller receives structured error; supervisor does not restart (per-call failure) |
| Plugin GenServer crashes | Supervisor notices | Supervisor restarts; state is rebuilt from config |
| Plugin supervisor crashes repeatedly | Supervisor `max_restarts` exceeded | Integration quarantined; status dashboard shows "plugin crash loop"; admin action required (`ERR-901`, `ERR-902`) |
| Database unavailable | Ecto emits errors | LiveView shows "temporarily unavailable"; Oban retries background work; reconnection is automatic |
| Phoenix endpoint crashes | Top supervisor | Restarted; existing WebSocket connections dropped; clients auto-reconnect (`STR-802`) |
| Entire BEAM node crashes | External orchestrator | Typically a systemd restart or Kubernetes pod replacement |

The architecture ensures that every one of these is either handled transparently (circuit breaker, supervisor restart) or surfaced to the administrator in a single place (the integration status dashboard).

---

[← Previous: Overview](01-overview.md) | [Next: Plugin Framework →](03-plugin-framework.md)

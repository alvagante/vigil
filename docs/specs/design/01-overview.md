# 1. Architectural Overview

## 1.1 System shape

Vigil is a single Elixir umbrella application rendering HTML over WebSockets via Phoenix LiveView, fronted by a PostgreSQL database, with one process tree per configured integration. There is no separate frontend; there is no message broker; there is no external cache. The BEAM node is the runtime.

```
                            +-------------------------+
                            |       Browser (TLS)     |
                            |   LiveView WebSocket    |
                            +------------+------------+
                                         |
                                         | HTTPS / WSS
                                         |
 +---------------------------------------+---------------------------------------+
 |                            Vigil BEAM node (OTP app)                          |
 |                                                                               |
 |  +-------------------+  +-------------------+  +---------------------------+  |
 |  | Phoenix Endpoint  |  |  MCP Endpoint     |  |   Background jobs (Oban)  |  |
 |  |  (LiveView, API)  |  | (tool over HTTP)  |  |  health, refresh, retention |
 |  +---------+---------+  +---------+---------+  +-------------+-------------+  |
 |            |                      |                          |                |
 |            +----------+-----------+--------------------------+                |
 |                       |                                                       |
 |           +-----------+------------+                                          |
 |           |    Vigil.Core           |  (pure domain, Ecto, PubSub topics)     |
 |           |  contexts: inventory,   |                                          |
 |           |  journal, execution,    |                                          |
 |           |  rbac, audit, linking   |                                          |
 |           +-----------+------------+                                           |
 |                       |                                                       |
 |           +-----------+------------+                                           |
 |           |  Vigil.Integrations    |  (per-integration supervisors)           |
 |           |                        |                                          |
 |  +---------+---------+  +---------+---------+  +-----------------------+      |
 |  | Puppet.Supervisor |  | Bolt.Supervisor   |  | AWS.Supervisor (...)  |      |
 |  |  +-------------+  |  |                   |  |                       |      |
 |  |  | PuppetDB    |  |  |                   |  |                       |      |
 |  |  | Puppetserver|  |  |                   |  |                       |      |
 |  |  | Hiera       |  |  |                   |  |                       |      |
 |  |  +-------------+  |  |                   |  |                       |      |
 |  +-------------------+  +-------------------+  +-----------------------+      |
 |                                                                               |
 +-------------------------------------------------------------------------------+
                                         |
                        +----------------+---------------+
                        |        PostgreSQL              |
                        |  journal, executions, users,   |
                        |  roles, audit, config, links   |
                        +--------------------------------+
```

## 1.2 Key architectural decisions

> **Decision: Phoenix LiveView for the UI, not a SPA.**
> Live-updating monitoring, journal feeds, execution streaming, progress reporting — these are the dominant UI patterns. LiveView makes them close to free. A SPA would require a parallel client, two sources of truth, and a WebSocket protocol of our own. The PRD specifies HTML deep-linking, keyboard operation, accessibility, and responsive layout — all native to LiveView.

> **Decision: Plugins are OTP applications, in-process, supervised.**
> The PRD (`PLUG-405`) permits in-process plugins for performance and explicitly says process-level isolation is not required but must not be precluded. BEAM processes give us *per-operation* isolation — stronger than per-module isolation in most runtimes — at negligible overhead. Each plugin is its own OTP application with its own supervision tree under a top-level `Vigil.Integrations` supervisor. Failure of one integration's call does not even trip the breaker on another.

> **Decision: PostgreSQL is the only persistent store.**
> Journal, executions, configuration, audit, users, roles, linking overrides, retention — all PostgreSQL. No Redis for caching, no Elasticsearch for search, no time-series DB for history. We get strong consistency for RBAC and audit, JSONB for the heterogeneous payloads journal and reports carry, full-text search for journal content, and SKIP LOCKED for job queues. Scale at 10,000 nodes is well inside what a single PostgreSQL instance handles.

> **Decision: Caching in ETS, keyed by integration + capability + principal scope.**
> `CACHE-006` requires cache keys scoped to the requesting principal's permission scope. An external cache with per-principal namespacing is buildable but adds an operational dependency for a problem ETS solves in-node with no network hop. Cache sizes are bounded per integration, eviction is LRU, and invalidation is a `:ets.select_delete/2`.

> **Decision: Oban for background jobs.**
> Health checks, scheduled inventory refresh, AI calls, retention purges — all are background work. Oban gives us persisted jobs in PostgreSQL, cron scheduling, retries with backoff, per-queue concurrency limits, and a dashboard. No external broker. PRD `FUT-101` (scheduled executions) plugs into the same layer.

> **Decision: Phoenix.PubSub for cross-process eventing.**
> Integration health updates, execution output, cache invalidations all flow over named PubSub topics. LiveView processes subscribe. MCP tools subscribe. The plugin framework subscribes. There is no request-response dance between the UI and integrations; there is publish-subscribe to topics the UI and the domain layer both know about.

> **Decision: One Ecto Repo, multi-tenant-capable schemas.**
> `FUT-401` hints at multi-tenancy without committing. All tenant-sensitive tables carry a `tenant_id` column, defaulting to a single "default" tenant in single-tenant deployments. If multi-tenancy becomes scope, no schema migration is required — only query scoping and Ecto prepare-queries.

> **Decision: Streaming output to LiveView via a per-execution GenServer.**
> Each execution gets a supervised `Vigil.Execution.Stream` GenServer that owns the subprocess (or API polling), buffers output, and broadcasts chunks on a PubSub topic named for the execution ID. LiveView subscribes. Disconnect/reconnect is handled by LiveView's built-in session resumption and a short server-side buffer. `STR-203` (client disconnect doesn't affect server execution) is native.

> **Decision: Mix releases with runtime configuration (config/runtime.exs).**
> Single-artifact deployments, no Erlang/Elixir runtime required on target hosts. Configuration via environment variables or a mounted config file at boot time — compatible with typical Docker / Kubernetes deployments without requiring a container-native abstraction.

## 1.3 Technology stack

| Concern | Library / tool | Rationale |
|---------|---------------|-----------|
| Web framework | **Phoenix 1.8+** | Target framework; stable LiveView |
| UI rendering | **Phoenix LiveView 1.1+** | Server-rendered interactive UI over WebSocket |
| HTML components | **Phoenix.Component + LiveView.JS** | Typed function components; minimal JS |
| Styling | **Tailwind CSS + Phoenix UI primitives** | Predictable, utility-first; works well with LiveView |
| ORM | **Ecto 3.x** | First-class for PostgreSQL |
| Database | **PostgreSQL 15+** | Single store; JSONB, FTS, SKIP LOCKED |
| Background jobs | **Oban** | Postgres-backed, supervised, cron-capable |
| HTTP client | **Finch + Req** | Pooled, timeouts, telemetry; Req for ergonomics |
| Circuit breaker | **:fuse** or custom GenServer | Per-integration, per-capability |
| Caching | **:ets + Cachex (optional)** | In-process, scoped, bounded |
| Password hashing | **Argon2 (argon2_elixir)** | Current best-practice |
| Authentication (session) | **phx_gen_auth** generator base | Local auth; then extended |
| SAML | **Samly** or **esaml** | SAML 2.0 IdP integration |
| OIDC | **openid_connect** (or **Ueberauth + strategy**) | OIDC authentication |
| LDAP | **Exldap** | LDAP bind + search |
| Webhooks (inbound) | Phoenix controller + Oban job | Ingest async |
| Telemetry | **:telemetry + TelemetryMetricsPrometheus** | Metrics export |
| Logging | **Logger + LoggerJSON** | Structured logs |
| Testing | **ExUnit + StreamData + Wallaby/PhoenixTest** | Unit, property, E2E |
| Release tooling | **mix release** | Single-artifact deploy |
| Runtime container | **Alpine / Debian slim + ERTS** | Standard; no special requirements |

The stack is deliberately boring. Every library named here is widely used in production Elixir deployments, has a maintenance track record, and composes naturally with the others.

## 1.4 What's not in the stack

- **No GraphQL.** The UI is LiveView, not a SPA. The API is REST-ish for the CLI and MCP server. A GraphQL layer would duplicate Ecto's composition.
- **No Redis.** ETS for caching; Oban for queues; PubSub for eventing. Each replaces a common Redis use case with an in-node primitive.
- **No Elasticsearch.** PostgreSQL full-text search covers journal content search. `tsvector` with a GIN index is within target at 10,000 nodes × reasonable journal entry volume.
- **No separate TSDB.** Per PRD `SCOPE-111`, Vigil does not store metrics. Monitoring data is read through at query time and cached short-term in ETS.
- **No service mesh.** Single-node deployment is the default. Multi-node deployment uses BEAM distribution (libcluster) only for sharing PubSub across nodes when horizontal scaling is needed.
- **No frontend build system beyond esbuild.** Tailwind runs via the Phoenix-integrated plugin. No Webpack, no Vite, no React.

## 1.5 Application boundaries

The umbrella application is split into these child applications, described fully in [section 2](02-application-topology.md):

| Application | Purpose |
|-------------|---------|
| `vigil_core` | Domain logic: inventory, journal, execution, RBAC, audit. Ecto schemas and contexts. Defines extension behaviours (`Vigil.Auth.Provider`, `Vigil.Audit.Exporter`, `Vigil.Execution.ApprovalGate`, `Vigil.Cluster.Backend`, `Vigil.Webhook.Dispatcher`, `Vigil.Scheduler.Backend`, `Vigil.Dashboard.Store`, `Vigil.Tenant.Resolver`) with no-op or minimal CE defaults. No web. No integrations. |
| `vigil_plugin` | Plugin behaviour definitions, dispatch, lifecycle, conformance suite. No specific plugins. |
| `vigil_web` | Phoenix endpoint, LiveView modules, controllers, API (including MCP). Depends on core + plugin. |
| `vigil_auth_oidc` | CE OIDC provider (single IdP, literal group-to-role mapping). Implements `Vigil.Auth.Provider`. |
| `vigil_integrations_puppet` | Puppet plugin. |
| `vigil_integrations_bolt` | Bolt plugin. |
| `vigil_integrations_ansible` | Ansible plugin. |
| `vigil_integrations_ssh` | SSH plugin. |
| `vigil_integrations_proxmox` | Proxmox plugin. |
| `vigil_integrations_aws` | AWS plugin. |
| `vigil_integrations_azure` | Azure plugin. |
| `vigil` (root) | Orchestrating application that starts all the children in the right order. |

Each integration is its own OTP application because:

1. Dependencies are isolated — AWS SDK brings heavy transitive deps the SSH plugin does not need.
2. Per-plugin enable/disable (`PLUG-206`) is a matter of starting or stopping the child application.
3. Community plugins follow exactly the same pattern — an OTP application declaring a dependency on `vigil_plugin`.

Enterprise Edition features (SAML, LDAP, multi-IdP OIDC, HA, approvals, SIEM export, scheduled executions, webhooks, custom dashboards, multi-tenancy) live in a separate `vigil_enterprise` umbrella outside this repository. They register into CE's extension points at runtime. CE works fully without EE loaded.

## 1.6 Cross-cutting principles

The following principles are derived from the PRD and shape every section that follows.

- **Let it crash, at the right boundary.** Integration calls can fail freely — the supervisor restarts; the circuit breaker tracks; the calling LiveView shows the stale data with a marker. The application process does not crash.
- **No synchronous blocking in the hot path.** The inventory page does not block on a slow source. Each source returns via `Task.yield_many/2`; whatever is ready is rendered.
- **Backpressure before rejection.** Concurrency limits (`PERF-007`, `EXEC-301`) are enforced via `Task.Supervisor` pools and `Flow`-style flow control. When a pool is full, the request queues briefly, then fails with a structured error the UI surfaces.
- **Every tick has a deadline.** No `:infinity` timeouts on external calls. Deadlines propagate through the call chain so the HTTP request has a budget shared by the integrations it consults.
- **Observability is part of the contract.** Every integration call emits a `[:vigil, :integration, capability, :start|:stop|:exception]` telemetry span. The metrics and logs are driven by these, not by ad-hoc instrumentation.
- **Context boundaries are real.** `Vigil.Core.Inventory` does not know what a Puppet plugin is. It knows what the plugin behaviour looks like. `Vigil.Web.Live.InventoryLive` does not query Ecto directly — it calls `Vigil.Core.Inventory`. Coupling flows one direction.

---

[↑ Back to index](00-index.md) | [Next: Application Topology →](02-application-topology.md)

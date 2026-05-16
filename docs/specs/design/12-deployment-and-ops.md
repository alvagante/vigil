# 12. Deployment & Operations

This section realizes `NFR-101..1603` operational concerns: deployment topology, observability, configuration management, backups, upgrades, logging, and health endpoints.

## 12.1 Deployment artifact

We ship **Mix releases**. A Mix release is a self-contained directory with:

- Compiled Erlang/Elixir BEAM files
- ERTS (Erlang runtime)
- `bin/vigil` control script (`start`, `stop`, `rpc`, `remote`, `migrate`)
- `config/runtime.exs` loaded at boot

No Erlang, Elixir, or mix is required on the target host.

### 12.1.1 Container image

Default distribution: Docker/OCI image. Dockerfile uses a multi-stage build:

```dockerfile
# Build stage
FROM hexpm/elixir:1.18.0-erlang-27.1-alpine AS build
WORKDIR /app
ENV MIX_ENV=prod
COPY mix.exs mix.lock ./
COPY apps/*/mix.exs ./apps/*/
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get --only prod
COPY . .
RUN mix deps.compile
RUN mix assets.deploy
RUN mix release

# Runtime stage
FROM alpine:3.20 AS runtime
RUN apk add --no-cache openssl ncurses libstdc++ libgcc bash openssh-client
WORKDIR /app
COPY --from=build /app/_build/prod/rel/vigil ./
ENV LANG=C.UTF-8
USER nobody
EXPOSE 4000
CMD ["bin/vigil", "start"]
```

Image is intentionally small — Alpine base plus ERTS. Plugins bundled in the release (Puppet, Bolt, etc. plugin modules included in the compilation).

### 12.1.2 Installation paths

Three deployment shapes supported:

1. **Container orchestration (Kubernetes, Nomad, Docker Compose).** Recommended for most deployments. Environment variables drive configuration.
2. **systemd on bare metal / VM.** Release tarball unpacked to `/opt/vigil`; systemd unit starts the release. Configuration via `/etc/vigil/vigil.env`.
3. **Development.** `mix phx.server` directly; sqlite or local postgres.

### 12.1.3 Dev-time MCP tooling (Tidewave)

In development, the application exposes a runtime MCP endpoint via [Tidewave](https://hexdocs.pm/tidewave/). This gives coding agents direct access to the running application context — evaluating code, querying the database through Ecto, reading logs, inspecting schemas, and looking up module documentation by name.

**Setup:**

Add to `apps/vigil_web/mix.exs` (dev-only):

```elixir
{:tidewave, "~> 0.1", only: :dev}
```

Tidewave auto-mounts at `/tidewave/mcp` on the Phoenix endpoint. The MCP client connects as an HTTP-type server:

```json
{
  "tidewave": {
    "type": "http",
    "url": "http://localhost:4000/tidewave/mcp"
  }
}
```

**Available tools:**

| Tool | Purpose |
|------|---------|
| `project_eval` | Evaluate Elixir expressions in the running app context |
| `get_docs` | Fetch documentation for any module/function by name |
| `get_source_location` | Find where a module/function is defined |
| `get_logs` | Read application logs from the running system |
| `get_schemas` | Inspect Ecto schemas from the runtime |
| `execute_sql_query` | Run SQL through the app's Ecto repo connection |

> **Decision: Tidewave is dev-only, never in production.**
> It provides unrestricted eval and SQL access — invaluable for development velocity but a security liability in any other environment. The `only: :dev` constraint ensures it is not compiled into releases.

## 12.2 Runtime configuration

Configuration is loaded at release boot by `config/runtime.exs`:

```elixir
# config/runtime.exs
import Config

# Database
config :vigil, Vigil.Repo,
  url: System.get_env("DATABASE_URL") || raise("DATABASE_URL not set"),
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "20")),
  ssl: System.get_env("DB_SSL") == "true"

# Endpoint
config :vigil_web, VigilWeb.Endpoint,
  url: [host: System.get_env("APP_HOST") || "localhost", port: 443, scheme: "https"],
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
  secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
  check_origin: String.split(System.get_env("ALLOWED_ORIGINS", ""), ",", trim: true)

# Secrets
config :vigil, Vigil.Core.Secrets,
  encryption_key: System.fetch_env!("VIGIL_SECRETS_KEY")

# PubSub multi-node
if System.get_env("CLUSTER_ENABLED") == "true" do
  config :libcluster, :topologies,
    vigil: [strategy: Cluster.Strategy.Kubernetes, ...]
end

# Oban
config :vigil, Oban,
  repo: Vigil.Repo,
  queues: [
    default: 10,
    webhooks: 10,
    maintenance: 3,
    ai: 5
  ]
```

Validation (`NFR-902`): `runtime.exs` raises on missing required vars. A `Vigil.Config.Validator` runs after Ecto starts to check cross-field constraints (e.g., if `CLUSTER_ENABLED=true`, `CLUSTER_SECRET` must be set).

### 12.2.1 Secrets bootstrap

`VIGIL_SECRETS_KEY` is the master key for encrypting integration credentials. It can be:

- An environment variable.
- A reference to a file path (e.g., `VIGIL_SECRETS_KEY_FILE=/run/secrets/vigil_key`).
- A reference to a cloud secrets manager (Phase 2).

On first boot without a key, `mix release` generates one and prints instructions. Rotation is an operator procedure — re-encrypt rows under a new key, migrate the key ID.

### 12.2.2 Hot config reload

`NFR-903`: configuration reloadable without restart where possible. Categories:

| Config | Reloadable at runtime? |
|--------|------------------------|
| Integration config (TTLs, timeouts, concurrency) | Yes — `ConfigServer` hot-updates |
| Integration enable/disable | Yes — supervisor start/stop child |
| Integration credentials | Yes — plugin re-initializes |
| Role permissions | Yes — invalidates permission cache |
| RBAC / linking rules | Yes — next evaluation uses new rules |
| Retention policy | Yes — next job run uses new policy |
| `VIGIL_SECRETS_KEY`, `DATABASE_URL`, `SECRET_KEY_BASE` | No — requires restart |
| Phoenix endpoint host/port/TLS | No — requires restart |

## 12.3 Database

### 12.3.1 Schema management

Migrations via `ecto.migrate`. Run at release boot (or manually):

```bash
bin/vigil eval "Vigil.Release.migrate"
```

`Vigil.Release.migrate` is a release-level module that starts only what's needed for migration (Ecto, no Phoenix, no plugins) — idempotent, safe to run pre-start in container orchestrators.

### 12.3.2 Connection pool

`Ecto.Repo` uses `DBConnection` pooling. Size defaults to `2 * concurrent_users + background_jobs`. At the target (10 users, moderate background), a 20-connection pool is comfortable. The pool is configurable per `DB_POOL_SIZE`.

### 12.3.3 Required extensions

PostgreSQL extensions:

- `uuid-ossp` or `pgcrypto` for UUID generation (gen_random_uuid).
- `pg_trgm` for trigram indexes on fact search (optional but recommended).
- `btree_gin` for GIN support on btree types (used in journal indexes).

No custom extensions required.

### 12.3.4 Backups

`NFR-1101`: standard `pg_dump` is supported. For larger deployments, logical replication or streaming backup via `pgbackrest` / cloud-managed snapshots are recommended.

Derived data (ETS caches) is not backed up — it's reconstructible from the sources.

## 12.4 Observability

### 12.4.1 Metrics

Exported via `/metrics` endpoint (`NFR-1003`). Implemented with `TelemetryMetricsPrometheus`:

```elixir
defmodule Vigil.Telemetry.Metrics do
  import Telemetry.Metrics

  def metrics do
    [
      # Phoenix
      counter("phoenix.endpoint.stop.duration",       tags: [:route, :status]),
      distribution("phoenix.endpoint.stop.duration",   tags: [:route]),

      # Ecto
      summary("vigil.repo.query.duration",             tags: [:source]),

      # Integration calls
      counter("vigil.plugin.call.stop.duration",       tags: [:plugin, :capability, :result]),
      summary("vigil.plugin.call.stop.duration",       tags: [:plugin, :capability]),
      last_value("vigil.plugin.health.overall",        tags: [:integration_id]),

      # Cache
      counter("vigil.cache.hit",                       tags: [:integration_id, :capability]),
      counter("vigil.cache.miss",                      tags: [:integration_id, :capability]),
      last_value("vigil.cache.size_bytes",             tags: [:integration_id]),

      # Executions
      counter("vigil.execution.started",               tags: [:integration_id]),
      last_value("vigil.execution.active",             tags: [:integration_id]),

      # Circuit breakers
      counter("vigil.circuit_breaker.opened",          tags: [:integration_id, :capability]),
      counter("vigil.circuit_breaker.reset",           tags: [:integration_id, :capability]),

      # Oban
      counter("oban.job.stop.duration",                tags: [:queue, :state]),
      summary("oban.job.stop.queue_time",              tags: [:queue])
    ]
  end
end
```

Exposed to Prometheus scrapers. Compatible dashboards in Grafana cover:

- Integration health over time.
- Per-integration call rate and latency.
- Cache hit rate.
- Request latency percentiles.
- Oban queue depth and throughput.
- Circuit breaker events.

### 12.4.2 Logging

Structured JSON logs via `LoggerJSON`:

```elixir
config :logger,
  backends: [LoggerJSON],
  level: :info

config :logger_json, :backend,
  formatter: LoggerJSON.Formatters.GCE,     # or DataDog, Elastic
  metadata: [:request_id, :user_id, :integration_id, :correlation_id]
```

Every log line includes the correlation ID set at the request boundary. Audit trail uses `correlation_id` to cross-reference user-facing errors with log records (`ERR-504`).

Secret filter is a `Logger.backend` hook that walks the metadata and payload looking for known secret shapes and replaces them with `[REDACTED]` (`NFR-1004`, `ERR-502`).

### 12.4.3 Health endpoint

`/healthz` endpoint for load balancers:

```elixir
def check(conn, _) do
  checks = %{
    db: db_alive?(),
    pubsub: pubsub_alive?(),
    oban: oban_alive?()
  }

  status = if Enum.all?(checks, fn {_, v} -> v == :ok end), do: 200, else: 503
  conn |> put_status(status) |> json(%{status: status, checks: checks})
end
```

A separate `/readyz` returns 200 only after all plugins have completed initial health checks — useful for Kubernetes readiness probes to avoid routing traffic before plugins are ready.

### 12.4.4 Error tracking

Crashes, exceptions, and structured errors at severity >= :error are forwarded to an external error tracker (Sentry via `sentry` library). Configuration is optional — unset the DSN to disable.

## 12.5 Upgrades

`NFR-1201..1203`:

- **Standard upgrade path:** deploy new release, run migrations, restart. Ecto migrations are reversible where possible.
- **Plugin contract compatibility:** on boot, the platform checks each loaded plugin's `contract_version/0` against `Vigil.Plugin.current_version/0`. Incompatible plugins are quarantined and surfaced in the admin UI; the platform still boots.
- **Rolling upgrade (multi-node):** supported as long as contract version is compatible and Ecto migrations are backward-compatible. The standard two-step migration pattern (add columns in v1, use them in v2) applies.
- **Downgrade:** supported within a minor version; across majors, operators should restore from backup.

### 12.5.1 Migration-safe deployment pattern

For changes that affect schema:

1. **v1:** ship the migration that adds the new column / table. Code continues to read old shape.
2. **v2:** ship code that writes to the new shape.
3. **v3:** ship code that reads from the new shape; remove old reads.
4. **v4:** drop the old column.

This pattern keeps rolling deployments safe. CI enforces it with a migration diff test.

## 12.6 Horizontal scaling

Single-node handles the target scale comfortably. Multi-node deployment is an Enterprise Edition capability delivered by FS EE-2 (HA): libcluster, distributed PubSub, session affinity. CE ships single-node-only — a CE deployment attempting to start with `CLUSTER_ENABLED=true` logs a clear "requires EE" error and continues as single-node.

When scaling out in EE:

- **Stateless by design.** Phoenix endpoints are stateless. Sessions are DB-backed.
- **Sticky WebSockets.** LiveView uses WebSocket; a stickiness cookie at the load balancer keeps a client on the same node for the duration of the connection. Required for every multi-node deployment.
- **Recommended API-token affinity.** REST and MCP endpoints are stateless HTTP. For clients making repeated requests with the same API token, hashing on the `Authorization` header at the load balancer preserves per-node ETS cache hit rates (see design/05 §5.11.2). This is a recommendation, not a hard requirement: without it, cache effectiveness degrades roughly as `1/N` per principal across N nodes, which may be acceptable depending on workload.
- **Per-node rate limiting scope.** MCP and other rate limits are enforced per-node (see design/10 §10.1.7). When sizing limits in multi-node deployments, set per-node limits to `expected_global / node_count`.
- **PubSub fan-out.** `Phoenix.PubSub` with `:pg` adapter distributes messages across nodes.
- **PostgreSQL:** shared.
- **Oban:** jobs distribute across nodes; each node processes any queue it's configured for.
- **libcluster:** joins nodes into a BEAM cluster via configured strategy (Kubernetes, DNS, gossip).

For very large deployments (tens of thousands of nodes), integrations can be pinned to specific BEAM nodes — e.g., the "PuppetDB node" has the Puppet plugin supervisor; the "AWS node" has AWS plugin supervisor. This partitions load naturally.

### 12.6.1 Load-balancer configuration reference

Vigil does not ship a load balancer; operators configure their own. The following examples realise the two stickiness recommendations above:

**HAProxy:**
```
frontend vigil_ui
    bind *:443 ssl crt /etc/ssl/vigil.pem
    acl is_websocket hdr(Upgrade) -i WebSocket
    acl is_api path_beg /api /mcp
    use_backend vigil_ws  if is_websocket
    use_backend vigil_api if is_api
    default_backend vigil_ui

backend vigil_ws
    balance source                           # WebSocket stickiness by client IP
    server node1 10.0.0.1:4000 check
    server node2 10.0.0.2:4000 check

backend vigil_api
    balance hdr(Authorization)               # API/MCP stickiness by token
    hash-type consistent
    server node1 10.0.0.1:4000 check
    server node2 10.0.0.2:4000 check

backend vigil_ui
    balance roundrobin                       # stateless HTML; no stickiness needed
    server node1 10.0.0.1:4000 check
    server node2 10.0.0.2:4000 check
```

**nginx** uses the `sticky` module for cookie-based stickiness and a `hash $http_authorization consistent;` directive for the API/MCP upstream. AWS ALB uses target-group stickiness (duration-based) for UI, and application-defined routing rules for the API — but ALB does not natively hash on request headers. For ALB, either accept reduced cache hit on API/MCP or place the MCP/API on a separate NLB with source-IP affinity as a proxy for principal affinity.

## 12.7 Operational runbooks

### 12.7.1 Integration troubleshooting

A failing integration typically shows in the admin dashboard with a diagnostic. From there:

- **Click "test connection"** → exercises a low-cost call, reports per-sub-system result.
- **View recent error** → the dashboard surfaces the last error from the log.
- **Manually trigger health check** → reruns the probe immediately.
- **Reload credentials** → re-reads secrets and restarts the integration's clients.
- **Disable** → stops the integration's supervisor. Caches remain readable.

### 12.7.2 Database maintenance

Routine maintenance jobs run as Oban cron jobs:

- Retention expiration (executions, audit per respective policies).
- `VACUUM ANALYZE` nudging for high-churn tables (Oban jobs, audit).
- Stale session cleanup.

None of these block user traffic.

### 12.7.3 Release checklist

Before a release ships:

- [ ] All migrations tested in a staging environment.
- [ ] Plugin contract version bumped if changed; plugins updated.
- [ ] Performance suite green at target scale.
- [ ] Resilience suite green (circuit breaker, timeout, reconnect, isolation).
- [ ] RBAC property tests green.
- [ ] Changelog updated.
- [ ] Upgrade guide updated for any operator-facing changes.

## 12.8 Resource budgets

Per `NFR-1601`, we document expected resource usage. Ballpark figures for a 10,000-node deployment with Priority 1 + 1b integrations enabled:

- **Memory:** 1.5–2 GB BEAM heap; ETS caches another 500 MB–1 GB.
- **CPU:** 2–4 cores typical. Vigil is primarily I/O bound: it issues HTTP requests to upstream tools, waits on responses, parses JSON, writes to ETS and Postgres. CPU-heavy work occurs in narrow windows — identity linker passes, Hiera usage-analysis reindexes, catalog diff computation, gzip of execution transcripts — and is typically under 1 core per operation. **Vigil does not compile Puppet catalogs**; catalog compilation is a Puppetserver responsibility. A catalog diff from Vigil's perspective is two HTTP calls plus a structural comparison; it costs milliseconds of CPU, not cores. Provision Puppetserver for catalog compilation load separately and do not use Vigil's CPU budget as a proxy.
- **Network:** proportional to upstream call volume; negligible for the platform itself.
- **Disk:** depends on execution transcript retention — at 30 days, modest for a typical deployment. Audit retention and checkpoint storage for long-running executions add a linear contribution with user activity.

These numbers are targets for release validation — regressions beyond 50% trigger review.

**Multi-node resource implications.** In a multi-node deployment (FS EE-2), per-node resource usage decreases roughly linearly with node count for stateless workloads. Cache memory usage is duplicated across nodes (each node holds its own ETS cache). Load-balancer stickiness recommendations (see design/05 §5.11.2 and §12.6 below) preserve cache hit rates for API clients.

## 12.9 Incident handling

For platform crashes:

- BEAM supervision recovers most faults without external intervention.
- If the BEAM node itself crashes, systemd / Kubernetes restarts it. State is re-read from Postgres on boot.
- Admin recovery actions (force disable a plugin, purge stuck jobs) are exposed in the admin UI and as `bin/vigil rpc` invocations.

### 12.9.1 Diagnostic tools

`bin/vigil remote` opens a remote shell into the running release. Operators can inspect supervision trees, ETS contents, GenServer state, and trigger ad-hoc commands. This is useful during incidents and is RBAC-bypassing (it's a local OS-level admin function) — guarded by OS permissions on the release directory.

### 12.9.2 Safety rails

For actions that could affect production data (hard-purge, mass-disable, etc.), CLI commands require a typed confirmation and log the action to the audit trail if possible.

---

[← Previous: Proxmox Integration](15-proxmox-integration.md) | [Next: Testing Strategy →](13-testing-strategy.md)

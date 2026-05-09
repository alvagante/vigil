# Tech Stack

The repository is currently in the **spec-and-design phase** — no application code yet. The authoritative architecture is in `docs/specs/design/`. When implementing, conform to it.

## Target stack

- **Language/runtime:** Elixir on the BEAM (Erlang/OTP 27+, Elixir 1.18+)
- **Web framework:** Phoenix 1.7+ with **Phoenix LiveView 0.20+** (server-rendered; no SPA)
- **UI:** Phoenix.Component + LiveView.JS, **Tailwind CSS**, esbuild — no React, no Webpack/Vite
- **Persistence:** **PostgreSQL 15+** as the single store, accessed via **Ecto 3.x**. Required extensions: `pgcrypto` (or `uuid-ossp`), `pg_trgm`, `btree_gin`
- **Background jobs:** **Oban** (Postgres-backed; cron, retries, per-queue concurrency)
- **Eventing:** **Phoenix.PubSub** for in-node and cross-node messaging
- **HTTP client:** **Finch + Req** (pooled, telemetry-integrated)
- **Caching:** **ETS** keyed by `integration + capability + principal scope` (no Redis)
- **Circuit breaker:** `:fuse` or equivalent GenServer, one per integration capability
- **Auth:** `argon2_elixir` (local), `Samly`/`esaml` (SAML), `openid_connect` (OIDC), `Exldap` (LDAP)
- **Observability:** `:telemetry`, `TelemetryMetricsPrometheus`, `LoggerJSON`
- **Testing:** ExUnit, **StreamData + PropCheck** (property-based), Phoenix.LiveViewTest, Wallaby + PhoenixTest (E2E), Mox (behaviour mocks only), ExCoveralls
- **Releases:** `mix release` into an Alpine-based OCI image; runtime config via `config/runtime.exs` + env vars

## Dev-only tooling

- **Tidewave** (`{:tidewave, "~> 0.1", only: :dev}`) — add to `vigil_web`'s `mix.exs` when scaffolding. Exposes an MCP endpoint at `/tidewave/mcp` giving the coding agent runtime access to: eval code in the app context, query the DB via Ecto, read logs, inspect schemas, and look up docs by module name. The MCP client entry (`~/.kiro/settings/mcp.json`) is pre-configured but disabled until the app runs.

## What's explicitly NOT in the stack

No GraphQL, no Redis, no Elasticsearch, no separate TSDB, no service mesh, no separate frontend build beyond esbuild + Tailwind.

## Common commands (once code lands)

```bash
# Dependencies & setup
mix deps.get
mix ecto.setup

# Dev server
mix phx.server

# Tests
mix test                              # fast subset (unit + essential integration)
mix test --include integration        # full integration suite
mix test --include perf               # performance suite (requires seeded DB)
mix test --include e2e                # Wallaby E2E (requires Chromedriver)

# Quality gates (must pass in CI)
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer

# Release
MIX_ENV=prod mix release

# External test deps (Postgres, PuppetDB, LocalStack, sshd, etc.)
docker compose up -d

# Release operations
bin/vigil start
bin/vigil remote
bin/vigil eval "Vigil.Release.migrate"
```

## Engineering rules

- **Let it crash** at the right boundary. Supervisors restart processes; circuit breakers track failures; LiveView renders stale data with a marker.
- **No `:infinity` timeouts** on external calls. Every tick has a deadline that propagates through the call chain.
- **Telemetry is contractual.** Every plugin capability call emits `[:vigil, :plugin, :call, :start|:stop|:exception]`. Metrics and logs derive from these, not ad-hoc instrumentation.
- **No secrets in logs.** A `Logger` filter redacts known-secret keys; plugins redact sensitive parameters before logging.
- **Prefer real over mocked** in tests: containerized Puppet, real Bolt, LocalStack for AWS, an sshd container. `Mox` is reserved for narrow pure-decision logic.
- **Context boundaries flow one direction.** `Vigil.Core` knows the plugin behaviour, not specific plugins. LiveView calls contexts, not Ecto directly.
- **Specs are the source of truth.** Every implementation change MUST have a corresponding update in `docs/specs/`. Code must never drift ahead of the spec. The workflow is: update spec → implement → verify alignment.
- **Consult upstream documentation.** When implementing or debugging integration plugins, always fetch and reference the official documentation for the tool's API or CLI. Do not rely on memory or assumptions about how an external tool works — verify against the source.

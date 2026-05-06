# Vigil — Architectural Design (Elixir / Phoenix LiveView)

**Document version:** 1.0
**Status:** Draft
**Audience:** Engineering
**Companion to:** [Product Requirements](../prd/00-index.md)

---

## About this document

This is the **architectural design** for a concrete Elixir / Phoenix LiveView implementation of Vigil. It is a companion to the [PRD](../prd/00-index.md): the PRD describes *what the system does*; this document describes *how this implementation does it*.

It is opinionated. It commits to specific libraries, process topologies, data models, and UI patterns. Where the PRD says "the system MUST support live updating," this document says "Phoenix.PubSub broadcasts on topic `X`; LiveView subscribes in `mount/3`."

It is not a product decision. The PRD remains implementation-agnostic. Any future reimplementation in a different stack would produce a different design document.

---

## Why Elixir / Phoenix LiveView

The match between BEAM/OTP and Vigil's requirements is unusually close:

| Vigil requirement | BEAM/OTP capability |
|-------------------|---------------------|
| Plugin isolation — one plugin failure MUST NOT crash the platform | Supervision trees, process isolation, let-it-crash |
| 100 concurrent streaming executions | Lightweight processes, per-stream GenServer |
| Live-updating UI without polling | Phoenix.PubSub + LiveView |
| Graceful degradation when a source is slow | Per-integration supervisor + timeouts + circuit breakers |
| Request coalescing / deduplication | Process-per-key via Registry |
| Streaming reconnect without lost output | LiveView auto-reconnect + server-side buffer in a GenServer |
| Long-running actions survive UI disconnect | Server-side process outlives the LiveView |
| In-process plugins without process-level isolation | Same BEAM node, still isolated by process supervision |
| Per-integration config reload without full restart | Hot-swap GenServer state; restart only the affected subtree |
| Observability | `:telemetry` spans everywhere, with zero extra dependencies |

Phoenix LiveView removes the SPA layer entirely: no separate REST / WebSocket client, no state synchronization bugs, no duplicated validation. The server renders HTML and diffs it over a WebSocket. For a node-centric operational UI (dense tables, live streams, drill-ins), it is the shortest path between "data changed" and "user sees it."

---

## Reading order

| # | File | Subject |
|---|------|---------|
| 1 | [01-overview.md](01-overview.md) | High-level architecture, key decisions, technology stack |
| 2 | [02-application-topology.md](02-application-topology.md) | OTP supervision tree, application structure, umbrella layout |
| 3 | [03-plugin-framework.md](03-plugin-framework.md) | Plugin behaviour, lifecycle, capability dispatch, isolation |
| 4 | [04-data-model.md](04-data-model.md) | Ecto schemas, PostgreSQL layout, derived vs. persisted data |
| 5 | [05-aggregation-and-caching.md](05-aggregation-and-caching.md) | Unified inventory, identity linking, cache layer, resilience |
| 6 | [06-execution-and-streaming.md](06-execution-and-streaming.md) | Remote execution platform, PubSub, LiveView streams |
| 7 | [07-journal-and-events.md](07-journal-and-events.md) | Journal pipeline, event extraction, live updates |
| 8 | [08-auth-rbac.md](08-auth-rbac.md) | Authentication, external IdPs, RBAC enforcement |
| 9 | [09-liveview-ui.md](09-liveview-ui.md) | LiveView topology, routing, component library, UX patterns |
| 10 | [10-mcp-and-ai.md](10-mcp-and-ai.md) | MCP server, AI inference, bring-your-own-keys |
| 11 | [11-puppet-integration.md](11-puppet-integration.md) | Detailed design of the Puppet plugin |
| 12 | [12-deployment-and-ops.md](12-deployment-and-ops.md) | Releases, deployment, observability, upgrades |
| 13 | [13-testing-strategy.md](13-testing-strategy.md) | How the PRD testing philosophy is realized |

---

## Conventions

- **Module names** use the canonical Elixir `App.Module.SubModule` form. The top-level application namespace is `Vigil`.
- **Process references** use `#PID<0.x.0>` notation only when concrete; elsewhere processes are referred to by the registered name or role (e.g., `Vigil.Integration.Registry`).
- **Messages** between processes are denoted `{:tag, payload}` matching Elixir conventions.
- **Code examples** are illustrative, not canonical. They show shape; actual implementations may vary in detail.
- **PRD references** use the form `PUP-301` — these map directly to the PRD requirement IDs and can be grep'd in the companion PRD.
- **Design decisions** are called out with a `> **Decision:**` block. They carry the rationale that would otherwise be lost to the reader.
- Requirements that are assumed or deferred are explicitly named.

---

## Out of scope for this document

- **Product requirements.** See the PRD.
- **Detailed plugin implementations** for every integration. This document covers the Puppet plugin in depth (mirroring the PRD's emphasis) and defines the shape all other plugins follow. Plugin-specific design documents may be added over time.
- **UX copy and visual design.** This document specifies LiveView topology, component boundaries, and data flow. Visual design lives in design files.
- **Infrastructure-as-code.** Deployment topology is covered; IaC templates are not.

---

## Traceability

Every requirement prefix from the PRD has a section in this document that describes how it is realized:

| PRD prefix | Design section |
|------------|----------------|
| `EXS`, `NFR` performance targets | [01](01-overview.md), [02](02-application-topology.md), [05](05-aggregation-and-caching.md), [12](12-deployment-and-ops.md) |
| `PLUG` plugin contract | [03](03-plugin-framework.md) |
| `PUP`, `BOLT`, `ANS`, `SSH`, `PROX`, `AWS`, `AZ` | [11](11-puppet-integration.md) plus per-plugin designs |
| `INV`, `CACHE`, `PERF`, `RES` | [05](05-aggregation-and-caching.md) |
| `EXEC`, `STR` | [06](06-execution-and-streaming.md) |
| `JRN`, `TYPE-JRN` | [07](07-journal-and-events.md) |
| `AUTH`, `RBAC` | [08](08-auth-rbac.md) |
| `UI` | [09](09-liveview-ui.md) |
| `MCP`, `AI` | [10](10-mcp-and-ai.md) |
| `HEALTH`, `ERR`, `CFG` | [02](02-application-topology.md), [05](05-aggregation-and-caching.md), [12](12-deployment-and-ops.md) |
| `DM` | [04](04-data-model.md) |
| `TEST` | [13](13-testing-strategy.md) |
| `FLOW` | Distributed across relevant sections, cross-referenced |

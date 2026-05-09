# Project Structure

The repository is currently a **spec-first project**: `docs/specs/` holds the authoritative PRD and architectural design. Code will land as an Elixir umbrella matching the layout below.

## Current layout

```
.
├── .kiro/                         # Kiro steering and specs
│   └── steering/                  # Steering rules (this directory)
├── docs/
│   └── specs/
│       ├── prd/                   # Product requirements (implementation-agnostic)
│       │   ├── 00-index.md        # Entry point, requirement-ID prefix table
│       │   ├── 01-executive-summary.md ... 21-future-considerations.md
│       └── design/                # Architectural design (Elixir/Phoenix, opinionated)
│           ├── 00-index.md
│           └── 01-overview.md ... 13-testing-strategy.md
```

## Planned code layout (Elixir umbrella)

Per `docs/specs/design/02-application-topology.md`:

```
vigil/                             # umbrella root
├── apps/
│   ├── vigil_core/                # Domain: inventory, journal, execution, RBAC,
│   │                              # audit, linking. Ecto schemas + contexts.
│   │                              # No web. No plugin specifics.
│   ├── vigil_plugin/              # Plugin behaviour, dispatcher, lifecycle,
│   │                              # conformance test suite. No concrete plugins.
│   ├── vigil_web/                 # Phoenix endpoint, LiveViews, controllers,
│   │                              # REST API, MCP server. Depends on core + plugin.
│   ├── vigil_integrations_puppet/
│   ├── vigil_integrations_bolt/
│   ├── vigil_integrations_ansible/
│   ├── vigil_integrations_ssh/
│   ├── vigil_integrations_proxmox/
│   ├── vigil_integrations_aws/
│   └── vigil_integrations_azure/
├── config/
│   ├── config.exs
│   ├── dev.exs
│   ├── test.exs
│   ├── prod.exs
│   └── runtime.exs                # Loaded at release boot
├── rel/                           # Mix release config
└── mix.exs                        # Umbrella root
```

## Dependency direction

```
vigil_web  →  vigil_core  ←  vigil_integrations_*
                  ↑
             vigil_plugin  ←  vigil_integrations_*
```

- `vigil_core` depends on nothing inside the umbrella (except optionally `vigil_plugin` behaviour definitions).
- Integration apps depend on `vigil_plugin` (for the behaviour) and `vigil_core` (for domain types).
- `vigil_web` depends on `vigil_core` and `vigil_plugin`; it does **not** depend on specific integrations.
- Each integration is a separate OTP app so heavy deps (AWS SDK, Azure SDK) are isolated and plugins can be enabled/disabled as child applications.

## Naming conventions

- **Modules:** `Vigil.<Context>.<Component>` (e.g., `Vigil.Core.Inventory.Linker`, `Vigil.Integrations.Puppet.PuppetDB.Client`).
- **Phoenix:** `VigilWeb.<Live|Controller>.<Name>` (e.g., `VigilWeb.InventoryLive`).
- **Requirement traceability:** Tests and commits reference PRD IDs (`INV-001`, `PUP-014`, etc.) from `docs/specs/prd/` so behaviour can be grep'd across PRD → design → code → tests.
- **PubSub topics:** colon-delimited, scoped by entity ID — `integration_health:<id>`, `node:<node_id>`, `execution_stream:<id>`, `journal:global`.
- **Telemetry events:** `[:vigil, :<area>, :<event>]` — e.g., `[:vigil, :plugin, :call, :stop]`, `[:vigil, :cache, :hit]`.

## Test organization

Each app has its own `test/` directory. Per `docs/specs/design/13-testing-strategy.md`:

- Unit tests alongside the module under test.
- `test/support/` for shared factories, data cases, and `Vigil.Core.TestData` generators.
- `test/integration/` for user-flow tests (one per numbered `FLOW-*` in the PRD).
- `apps/vigil_plugin/test/conformance/` defines the shared plugin contract suite; each integration's `conformance_test.exs` runs it against the plugin.
- Tests are tagged: default, `:integration`, `:perf`, `:e2e`.

## Working with specs

- **PRD (`docs/specs/prd/`)** is implementation-agnostic and RFC 2119 normative. Never embed language-specific details here.
- **Design (`docs/specs/design/`)** is opinionated Elixir/Phoenix. Decisions are called out with `> **Decision:**` blocks including rationale.
- When a requirement or decision changes, update the spec before the code, and reference the requirement ID in the commit/PR.

## CRITICAL: Specs are the source of truth

**Every implementation change MUST be reflected in `docs/specs/`**. The spec files are the single point of reference for all implementation plans, architectural decisions, and feature scope. Code that diverges from the specs without a corresponding spec update is considered incorrect. The workflow is always: update the spec first, then implement. Never let code drift ahead of documentation.

## Documentation rules

Documentation created alongside code must be **concise and non-redundant**. Do not repeat information that already exists elsewhere.

### Where things go

| Content | Location | Notes |
|---------|----------|-------|
| Agent session notes, summaries, scratchpads | `.kiro/summaries/` | Organized by date or topic. Internal only. |
| User-facing project docs (README, guides, API docs) | `docs/` | Short, actionable, no fluff. |
| Specs and architecture | `docs/specs/prd/` and `docs/specs/design/` | Authoritative. Updated before code. |
| Inline code docs | In the code (moduledoc, doc, comments) | Explain *why*, not *what*. |

### Principles

- **No redundancy across docs.** If something is explained in the specs, other docs should reference it, not restate it.
- **Concise over comprehensive.** Prefer a 5-line summary that links to the spec over a 50-line explanation that duplicates it.
- **`docs/` is for humans using the project** — setup guides, operational runbooks, contribution guides. Keep it lean.
- **`.kiro/summaries/` is for agent context** — session notes, decision logs, implementation progress. Organize coherently (e.g., by date or feature area) so future sessions can pick up where previous ones left off.

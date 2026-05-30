# 1. Executive Summary

## 1.1 Product vision

Modern infrastructure teams operate a hybrid estate — physical hardware, virtual machines, public cloud, containers — under the supervision of a hand-picked toolchain that grew up around it. A typical site runs Puppet for configuration management, Ansible or Bolt for orchestration, monitoring stacks that pre-date the move to cloud, vendor consoles for each provider, and a homegrown wiki that nobody trusts. Each tool has its own UI, its own login, its own data model, and its own opinion of what a "node" is.

**Vigil unifies the operator's view of that estate** without replacing any of the tools beneath it. It is a single, web-based command-and-control surface that aggregates inventory, facts, configuration, events, monitoring status, run reports, deployments, executions, and provisioning across heterogeneous infrastructure tooling. From one page an operator sees what a node is, what it's supposed to be, what's happening to it, and what changed.

Vigil does not build its own configuration management. It does not store its own metrics. It does not duplicate vendor consoles. It is the convergence point — where the answers from the tools you already use are presented as one estate, by one identity, on one timeline.

## 1.2 Target users

| User | What they do with Vigil |
|------|-------------------------|
| **Infrastructure engineer** | Inspect a node end-to-end without context-switching across five tools; run ad-hoc commands; trace a failure from the alert to the configuration that produced it. |
| **DevOps / SRE** | Investigate incidents using a unified timeline; provision cloud or on-prem instances; run playbooks against a curated target set; monitor cross-tool health. |
| **Platform team lead** | Govern access through RBAC; map IdP groups to roles; restrict execution to approved commands and modules; audit what was done by whom. |
| **On-call responder** | See current monitoring state alongside recent change events; run a remediation playbook; record manual journal notes. |
| **External AI agent / IDE assistant** | Query infrastructure state through the MCP server; produce structured summaries; respect the same RBAC as the human user. |

## 1.3 Value proposition

| Without Vigil | With Vigil |
|---------------|-----------|
| Five tools, five logins, five "node" definitions | One inventory deduplicated across sources, with attribution back to each |
| "What changed?" requires correlating logs from three places | A per-node journal aggregates events from configuration, monitoring, deployment, provisioning, execution |
| Provisioning a VM, configuring it, and running a check live in three UIs | All three flow through the same target, the same RBAC, the same audit trail |
| Tool failure produces a broken page | Tool failure is contained — other sources continue; cached data is served with a staleness indicator |
| AI assistants can't reason about infrastructure | The MCP server exposes well-shaped, RBAC-respecting tools that AI agents can consume |

## 1.4 Product principles

- **Convergence, not replacement.** Vigil shows what existing tools know. It does not edit Puppet code, manage monitoring rules, or run CI/CD pipelines. It does not become the fourth duplicate.
- **Node-centric.** Everything resolves to a node. Features that are not about "what's happening on or to a node" do not belong in Vigil.
- **Uniform plugin contract.** Built-in and community integrations follow the same interface. No special-cased internals.
- **Graceful degradation by default.** A failed integration produces a partial answer with a clear marker, not an error page.
- **Scale is a first-class constraint.** Every design choice is evaluated for what it does at several thousand nodes, not what it does at fifty.
- **RBAC is universal.** Web UI, MCP server, future CLI — all enforce the same permission model.

## 1.5 Scale requirements

| `EXS-001` | The system **MUST** support managed inventories of several thousand nodes (target: 10,000) without functional degradation. |
|-----------|---|
| `EXS-002` | The system **MUST NOT** scale aggregate latency linearly with the number of integrations enabled — adding integrations **MUST NOT** make the inventory page slower than its slowest source. |
| `EXS-003` | The system **MUST** support concurrent active users (target: 10) without queuing read requests. |
| `EXS-004` | The system **MUST** support concurrent streaming executions (target: 100 simultaneous streams) without dropping output. |
| `EXS-005` | The system **MUST NOT** issue redundant calls to upstream tool APIs when multiple users request the same data within a cache window. |
| `EXS-006` | The system **MUST** continue serving cached data when an upstream tool is unreachable, marking it as stale rather than removing it. |
| `EXS-007` | First-page render of any list view (inventory, journal, execution history) **MUST** complete in under 2 seconds at the target scale, given a healthy primary data source. |
| `EXS-008` | The system **MUST** paginate every list endpoint and **MUST NOT** rely on full-set materialization in any user-facing flow. |

## 1.6 Out of scope (high level)

The full scope boundary is in [03-scope.md](03-scope.md). At the level of this summary:

- Cloud cost or budget management
- Storage pool / network topology configuration
- Editing of Puppet modules, Ansible playbooks, monitoring rules, CI pipelines
- Metric storage, log aggregation, APM
- Pod / service / deployment management for Kubernetes (only node-level visibility is in scope)

---

[← Back to index](00-index.md) | [Next: Glossary →](02-glossary.md)

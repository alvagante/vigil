 # Vigil — Product Requirements & Specifications

**Document version:** 1.0
**Status:** Draft
**Audience:** Product, engineering, design, QA, integration partners

---

## About this document

This document defines the requirements for **Vigil**, a web-based command-and-control interface for infrastructure management. It describes what the system must do, how its parts relate, and the criteria by which any implementation is judged complete.

The document is **implementation-agnostic**. It does not prescribe a programming language, framework, persistence engine, transport protocol, or runtime topology. Where behavior depends on a technical choice, the requirement names the behavior, not the choice.

The product is delivered in two editions — **Community Edition (CE, AGPL v3)** and **Enterprise Edition (EE, commercial)**. Requirements in this document are CE unless explicitly marked **(EE)** or noted as an EE feature inline. The commercial and architectural rationale for the edition split lives in [`docs/specs/editions.md`](../editions.md); that document is normative for edition placement.

Requirements use RFC 2119 keywords (**MUST**, **SHOULD**, **MAY**, **MUST NOT**, **SHOULD NOT**). Each normative requirement carries a unique identifier of the form `PREFIX-NNN` (e.g., `INV-001`, `PUP-014`) for traceability across implementation, tests, and documentation.

---

## Reading order

The chapters below are ordered for cover-to-cover reading. They may also be consulted independently.

| # | File | Subject |
|---|------|---------|
| 1 | [01-executive-summary.md](01-executive-summary.md) | Vision, target users, value proposition, scale targets |
| 2 | [02-glossary.md](02-glossary.md) | Defined terms used throughout the document |
| 3 | [03-scope.md](03-scope.md) | What is in scope and what is explicitly out of scope |
| 4 | [04-integration-types.md](04-integration-types.md) | Formal definition of the nine integration types |
| 5 | [05-integration-matrix.md](05-integration-matrix.md) | Matrix of integrations by priority, with the types each provides |
| 6 | [06-plugin-architecture.md](06-plugin-architecture.md) | Uniform plugin contract, distribution, lifecycle, isolation |
| 7 | [07-puppet-integration.md](07-puppet-integration.md) | Detailed specification — Puppet (most detailed integration) |
| 8 | [08-priority-1-integrations.md](08-priority-1-integrations.md) | Bolt, Ansible, SSH |
| 9 | [09-priority-1b-integrations.md](09-priority-1b-integrations.md) | Proxmox, AWS, Azure |
| 10 | [10-priority-2-3-integrations.md](10-priority-2-3-integrations.md) | Lighter specifications for later integrations |
| 11 | [11-platform-requirements.md](11-platform-requirements.md) | Unified inventory, execution model, journal, auth, health, resilience, performance, configuration |
| 12 | [12-data-model.md](12-data-model.md) | Conceptual entities and relationships |
| 13 | [13-user-flows.md](13-user-flows.md) | Key end-to-end user scenarios |
| 14 | [14-realtime-streaming.md](14-realtime-streaming.md) | Streaming output, live updates, connection resilience |
| 15 | [15-error-handling.md](15-error-handling.md) | Failure modes, timeout behavior, user communication |
| 16 | [16-testing-philosophy.md](16-testing-philosophy.md) | What to test and what not to test |
| 17 | [17-ai-features.md](17-ai-features.md) | MCP server, AI inference, bring-your-own-keys |
| 18 | [18-ui-requirements.md](18-ui-requirements.md) | Information architecture, node detail page, UI driven by enabled integrations |
| 19 | [19-non-functional-requirements.md](19-non-functional-requirements.md) | Performance, security, reliability, extensibility, caching |
| 20 | [20-implementation-roadmap.md](20-implementation-roadmap.md) | Ordered feature sets with acceptance criteria |
| 21 | [21-future-considerations.md](21-future-considerations.md) | CLI tool, pointers to items moved into EE, drift detection, public views, mobile companion |

---

## Requirement identifier prefixes

Identifiers are stable. Once assigned, an ID is not reused even if its requirement is removed.

| Prefix | Domain |
|--------|--------|
| `EXS` | Executive summary, scale targets |
| `SCOPE` | Scope boundary requirements |
| `TYPE` | Integration type definitions |
| `PLUG` | Plugin architecture |
| `PUP` | Puppet integration |
| `BOLT` | Bolt integration |
| `ANS` | Ansible integration |
| `SSH` | SSH integration |
| `PROX` | Proxmox integration |
| `AWS` | AWS integration |
| `AZ` | Azure integration |
| `P2` | Priority 2 integrations |
| `P3` | Priority 3 integrations |
| `INV` | Unified inventory |
| `EXEC` | Remote execution platform |
| `JRN` | Node journal |
| `AUTH` | Authentication |
| `RBAC` | Authorization and roles |
| `HEALTH` | Health and observability |
| `RES` | Resilience patterns |
| `PERF` | Performance and scale |
| `CACHE` | Caching strategy |
| `CFG` | Configuration management |
| `DM` | Data model |
| `FLOW` | User flows |
| `STR` | Streaming and live updates |
| `ERR` | Error handling and degradation |
| `TEST` | Testing requirements |
| `MCP` | MCP server |
| `AI` | AI-assisted features |
| `UI` | User interface |
| `NFR` | Non-functional requirements |
| `ROAD` | Implementation roadmap |
| `FUT` | Future considerations |

---

## Conventions

- "**The system**" refers to Vigil as a whole.
- "**A plugin**" or "**an integration plugin**" refers to a unit implementing one or more integration types against an external tool.
- "**The user**" refers to a person interacting with the system through its web interface, API, MCP server, or future CLI.
- "**The administrator**" is a user with elevated privileges to configure the system, integrations, users, and roles.
- A requirement that names a specific integration applies only to that integration; cross-cutting requirements use generic terms.
- Requirements marked **(EE)** are provided by the Enterprise Edition (`vigil_enterprise`). A CE-only deployment **MUST NOT** be expected to satisfy them. See [`editions.md`](../editions.md) for placement rationale.

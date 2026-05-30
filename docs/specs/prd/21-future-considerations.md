# 21. Future Considerations

This section catalogs features planned beyond the initial phases. They are deliberately separated from the rest of the document because they are **not committed scope** for the initial release. Each section here is a sketch — enough detail that the architecture does not preclude the feature, but not enough to commit to a particular shape until the time comes.

> Future requirements use `FUT-NNN` identifiers. They are non-binding in the strict RFC 2119 sense — they describe direction, not obligation.

## 21.1 CLI tool

A command-line interface (`vigil`) that provides terminal-based access to the platform's capabilities.

### 21.1.1 Purpose

The CLI exists for three audiences:

- **Power users** who prefer the terminal over the web UI for routine operations.
- **Automation pipelines** (CI/CD, runbook execution, scripts) that need to query state or trigger actions programmatically.
- **Incident response** where the web UI is overkill or the responder is on a constrained connection (SSH session, mobile shell).

### 21.1.2 Capabilities

| ID | Future requirement |
|----|--------------------|
| `FUT-001` | The CLI **SHOULD** provide query capabilities: list inventory, get node detail, retrieve facts, retrieve journal entries, view execution history. |
| `FUT-002` | The CLI **SHOULD** provide action capabilities: run remote commands, trigger provisioning lifecycle operations, deploy code to environments. |
| `FUT-003` | The CLI **SHOULD** support multiple output formats: human-readable (default, with terminal-aware formatting), JSON (for scripting), table (for grep / awk pipelines). |
| `FUT-004` | The CLI **SHOULD** authenticate via API token (file-based or env-var) and support multiple named profiles for multi-environment use. |
| `FUT-005` | The CLI **MUST** use the same API and respect the same RBAC as the web UI. There is no CLI-specific permission model. |
| `FUT-006` | The CLI **SHOULD** stream execution output to the terminal in real time, with reconnection support consistent with the web UI's streaming contract. |
| `FUT-007` | The CLI **SHOULD** be distributable as a single static binary per platform (or equivalent), with no runtime dependencies beyond the OS. |
| `FUT-008` | The CLI **SHOULD** support shell-completion installation. |

### 21.1.3 Design constraints

- The CLI **MUST NOT** become a parallel feature codebase. It is a thin client over the existing API.
- The CLI **MUST NOT** require its own configuration of integrations — it talks to a configured Vigil deployment.
- The CLI **SHOULD** support config file resolution consistent with common terminal-tool conventions (project-local file, user file, env-var override).

## 21.2 Items moved into committed scope

The following items were noted as "considered but not committed" in earlier drafts. They now live in the committed roadmap and **MUST NOT** be duplicated here:

| Item | Destination | Reference |
|------|-------------|-----------|
| Scheduled executions | FS EE-5 (EE) | [`docs/specs/editions.md`](../editions.md), [roadmap §20.16](20-implementation-roadmap.md#2016-phase-2--enterprise-edition) |
| Custom dashboards | FS EE-7 (EE) | Same |
| Outbound webhooks | FS EE-6 (EE) | Same |
| Multi-tenancy | FS EE-8 (EE) | Same |
| Approval workflows | FS EE-3 (EE) | Same |

The identifier ranges previously used for these items in earlier drafts (`FUT-101..107`, `FUT-201..207`, `FUT-301..302`, `FUT-401..402`, `FUT-501..503`) are **preserved as pointers**: per the document convention in [00-index.md](00-index.md#requirement-identifier-prefixes) ("Once assigned, an ID is not reused even if its requirement is removed"), these IDs remain valid references. Where they appear in the PRD or design documents, they now denote the corresponding requirement as implemented in its EE feature set — not a future aspiration. The legacy text for each is listed below for traceability; the authoritative requirement lives in the feature set's acceptance criteria ([§20.16 of the roadmap](20-implementation-roadmap.md#2016-phase-2--enterprise-edition)) and the edition spec.

### 21.2.1 Scheduled executions — identifiers `FUT-101..107`

Implemented as **FS EE-5** (EE). The FUT identifiers remain valid as pointers to the EE feature set:

- `FUT-101..107` are satisfied by FS EE-5 acceptance criteria.
- `FUT-106` specifically — RBAC-at-execution-time — is called out as a first-class requirement of both FS EE-5 and `RBAC-108` (bounded-query evaluation), which applies at scheduled-execution run time.

### 21.2.2 Custom dashboards — identifiers `FUT-201..207`

Implemented as **FS EE-7** (EE).

### 21.2.3 Outbound webhooks — identifiers `FUT-301..302`

Implemented as **FS EE-6** (EE).

### 21.2.4 Multi-tenancy — identifiers `FUT-401..402`

Implemented as **FS EE-8** (EE). `FUT-401` remains the canonical pointer for the "tenant-ready schema" decisions made across the CE data model — those decisions stand regardless of which edition activates the tenant resolver.

### 21.2.5 Approval workflows — identifiers `FUT-501..503`

Implemented as **FS EE-3** (EE).

## 21.3 Drift detection cross-tool

| ID | Future requirement |
|----|--------------------|
| `FUT-601` | The platform **MAY** synthesize cross-tool drift detection — e.g., comparing observed Facts to declared Configuration to highlight nodes whose actual state diverges from desired state, when both sources are available. |
| `FUT-602` | Such detection **MUST** be an analysis layer over the existing data, not a new data acquisition surface. |

## 21.4 Read-only public views

| ID | Future requirement |
|----|--------------------|
| `FUT-701` | The platform **MAY** support sharable, read-only views of selected dashboards or node detail pages for incident communication or stakeholder updates, with explicit time-bounded access tokens. |
| `FUT-702` | Public views **MUST** redact sensitive data and **MUST** be revocable. |

## 21.5 Mobile companion

| ID | Future requirement |
|----|--------------------|
| `FUT-801` | The platform **MAY** ship a mobile companion (native or PWA) optimized for on-call response: receive alerts, acknowledge them, view the affected node's recent journal, run a small set of pre-approved remediation playbooks. |
| `FUT-802` | The mobile companion **MUST** authenticate, enforce RBAC, and operate against the same API as the web UI. It is a constrained client, not an alternate stack. |

## 21.6 Things that will NOT be added

These are noted to prevent scope creep:

- **Vigil-native configuration management.** Vigil never grows a desired-state engine of its own. Convergence with existing tools is the value; replacement breaks it.
- **Vigil-native monitoring.** Same reasoning. Vigil reads monitoring; it does not produce it.
- **Cloud cost or budget management.** Out of scope per [section 3](03-scope.md) and remains so.
- **A Kubernetes workload management UI.** Node-level visibility is the limit. Workload management belongs in tools built for it.
- **Multi-tenant SaaS hosted by the project.** The product is self-hosted; EE multi-tenancy (FS EE-8) addresses on-premise MSP and multi-BU cases. Project-operated SaaS is not a roadmap item for the open product.

| ID | Anti-requirement |
|----|------------------|
| `FUT-901` | The platform **MUST NOT** add the items listed in section 21.6 without an explicit, deliberate scope amendment that revisits the product's first principles in [section 1.4](01-executive-summary.md#14-product-principles). |

## 21.7 How to request a future feature

A future feature request earns its way into the document by:

1. Demonstrating the user job it serves.
2. Showing it fits the scope test — *is this about a node, or about a tool?*
3. Identifying which integration types or platform capabilities it depends on.
4. Sketching how it interacts with RBAC, the journal, and the plugin contract.

Items that pass these tests are added as new Future Considerations entries and, when prioritized, promoted to a feature set in the [implementation roadmap](20-implementation-roadmap.md).

---

[← Previous: Implementation Roadmap](20-implementation-roadmap.md) | [↑ Back to index](00-index.md)

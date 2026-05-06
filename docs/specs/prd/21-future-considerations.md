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

## 21.2 Scheduled executions

Cron-like scheduling for recurring commands, tasks, plans, and playbooks.

### 21.2.1 Purpose

Many operational tasks are inherently periodic: nightly snapshots, weekly compliance scans, hourly cache warmers. Today these run from external schedulers; bringing them inside Vigil unifies the audit trail and uses the same RBAC, allowlists, and execution integrations the rest of the system already enforces.

### 21.2.2 Capabilities

| ID | Future requirement |
|----|--------------------|
| `FUT-101` | The platform **SHOULD** support scheduled execution definitions: an execution integration, an artifact (command/task/playbook/plan), parameters, target spec, schedule expression, and ownership (the user / role on whose authority the schedule runs). |
| `FUT-102` | Schedule expressions **SHOULD** support cron-style timing and human-friendly intervals ("every 6 hours"). Timezone disambiguation is mandatory. |
| `FUT-103` | The platform **SHOULD** maintain scheduled-execution history with the same persistence as ad-hoc executions: full transcript, exit status, journal entries per target. |
| `FUT-104` | The platform **SHOULD** alert on scheduled execution failures — at minimum via the integration status / system event surface; optionally via outbound notification to configurable channels. |
| `FUT-105` | The platform **SHOULD** support pause / resume of a schedule and ad-hoc "run now" execution outside the schedule. |
| `FUT-106` | The platform **SHOULD** evaluate RBAC and allowlists against the schedule's owning principal at *execution time*, not at schedule-creation time, so revoked permissions stop the schedule from running. |
| `FUT-107` | The platform **SHOULD** prevent overlapping runs of the same schedule by default (configurable per schedule). |

### 21.2.3 Design constraints

- Scheduled executions **MUST NOT** bypass any of the security controls that govern interactive execution (RBAC, allowlists, granular permissions, concurrency limits).
- The platform **MUST NOT** introduce a third execution code path. Scheduled executions are interactive executions, just triggered by the scheduler instead of a user click.
- The schedule itself is configuration; modifying a schedule **MUST** be auditable.

## 21.3 Custom dashboards

User-configurable dashboard views composed from widgets.

### 21.3.1 Purpose

Different roles need different first-screen views: an SRE wants alert state and recent failures; an infrastructure lead wants integration health and capacity; an auditor wants change volume and audit trail summaries. A fixed home page can't serve all of them; configurable dashboards can.

### 21.3.2 Capabilities

| ID | Future requirement |
|----|--------------------|
| `FUT-201` | The platform **SHOULD** allow users to create custom dashboard views composed from a catalog of widgets. |
| `FUT-202` | Widget types **SHOULD** include at minimum: node count by group/source/status, recent journal entries with filter, integration health summary, recent execution history, custom query results, manual notes panel. |
| `FUT-203` | Dashboards **SHOULD** be shareable across users — a user creates a dashboard and grants others read or edit access, scoped per dashboard. |
| `FUT-204` | Dashboards **MUST** respect the viewing user's RBAC — widgets render only data the viewing user is permitted to see, regardless of who authored the dashboard. |
| `FUT-205` | Dashboards **SHOULD** support refresh intervals per widget so a dashboard is self-updating when left open. |
| `FUT-206` | A user **MAY** designate a dashboard as their default home page. |
| `FUT-207` | The platform **MAY** ship a small set of pre-built dashboards (e.g., "SRE on-call view", "Audit overview") as starting points users can clone and customize. |

### 21.3.3 Design constraints

- Dashboards **MUST NOT** introduce new query capabilities beyond what's already exposed via the API. Widgets are presentation; data sources are platform APIs.
- Dashboards **MUST** scale — a dashboard with 12 widgets refreshing every 30 seconds **MUST NOT** measurably impact platform load at the target scale.
- Dashboard configuration **MUST** be portable: users **SHOULD** be able to export a dashboard config and import it into another deployment.

## 21.4 Other deferred ideas

The following are explicitly noted as "considered but not committed." They are not roadmap items — they are signposts to keep the architecture friendly to future direction without committing to it.

### 21.4.1 Webhook outbound

| ID | Future requirement |
|----|--------------------|
| `FUT-301` | The platform **MAY** support outbound webhooks on events of interest (significant journal entries, execution completion, provisioning state transitions, integration health changes) so external systems can react. |
| `FUT-302` | Webhook deliveries **MUST** include retry with exponential backoff and signed delivery for authenticity. |

### 21.4.2 Multi-tenant deployment

| ID | Future requirement |
|----|--------------------|
| `FUT-401` | The platform **MAY** support multi-tenant deployments where one Vigil installation serves multiple isolated tenants with no data cross-leakage. |
| `FUT-402` | Multi-tenancy is a substantial scope expansion — most likely it would be a separate product variant rather than a flag on the existing product. |

### 21.4.3 Approval workflows

| ID | Future requirement |
|----|--------------------|
| `FUT-501` | The platform **MAY** support approval workflows for high-impact actions (production provisioning, destructive lifecycle operations, environment deployment) — the action is queued until an authorized approver releases it. |
| `FUT-502` | Approval state **MUST** be auditable. |
| `FUT-503` | This is a significant scope expansion and would likely warrant its own feature set rather than being retrofitted. |

### 21.4.4 Drift detection cross-tool

| ID | Future requirement |
|----|--------------------|
| `FUT-601` | The platform **MAY** synthesize cross-tool drift detection — e.g., comparing observed Facts to declared Configuration to highlight nodes whose actual state diverges from desired state, when both sources are available. |
| `FUT-602` | Such detection **MUST** be an analysis layer over the existing data, not a new data acquisition surface. |

### 21.4.5 Read-only public views

| ID | Future requirement |
|----|--------------------|
| `FUT-701` | The platform **MAY** support sharable, read-only views of selected dashboards or node detail pages for incident communication or stakeholder updates, with explicit time-bounded access tokens. |
| `FUT-702` | Public views **MUST** redact sensitive data and **MUST** be revocable. |

### 21.4.6 Mobile companion

| ID | Future requirement |
|----|--------------------|
| `FUT-801` | The platform **MAY** ship a mobile companion (native or PWA) optimized for on-call response: receive alerts, acknowledge them, view the affected node's recent journal, run a small set of pre-approved remediation playbooks. |
| `FUT-802` | The mobile companion **MUST** authenticate, enforce RBAC, and operate against the same API as the web UI. It is a constrained client, not an alternate stack. |

## 21.5 Things that will NOT be added

These are noted to prevent scope creep:

- **Vigil-native configuration management.** Vigil never grows a desired-state engine of its own. Convergence with existing tools is the value; replacement breaks it.
- **Vigil-native monitoring.** Same reasoning. Vigil reads monitoring; it does not produce it.
- **Cloud cost or budget management.** Out of scope per [section 3](03-scope.md) and remains so.
- **A Kubernetes workload management UI.** Node-level visibility is the limit. Workload management belongs in tools built for it.
- **Multi-tenant SaaS hosted by the project.** The product is self-hosted. A future commercial entity might offer SaaS, but that's not a roadmap item for the open product.

| ID | Anti-requirement |
|----|------------------|
| `FUT-901` | The platform **MUST NOT** add the items listed in section 21.5 without an explicit, deliberate scope amendment that revisits the product's first principles in [section 1.4](01-executive-summary.md#14-product-principles). |

## 21.6 How to request a future feature

A future feature request earns its way into the document by:

1. Demonstrating the user job it serves.
2. Showing it fits the scope test — *is this about a node, or about a tool?*
3. Identifying which integration types or platform capabilities it depends on.
4. Sketching how it interacts with RBAC, the journal, and the plugin contract.

Items that pass these tests are added as new Future Considerations entries and, when prioritized, promoted to a feature set in the [implementation roadmap](20-implementation-roadmap.md).

---

[← Previous: Implementation Roadmap](20-implementation-roadmap.md) | [↑ Back to index](00-index.md)

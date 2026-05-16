# 13. Key User Flows

This section describes the principal end-to-end scenarios. Each flow is the integration point of multiple requirements from across the document. A flow that does not work end-to-end means the system is not complete, regardless of which individual requirements pass. These flows are normative — the system **MUST** support each as written.

## 13.1 Flow 1 — Inventory browsing and node inspection

**Actor:** infrastructure engineer

**Pre-conditions:** the user is authenticated, has at minimum the `inventory:read` permission, and one or more inventory-capable integrations are configured and healthy.

| Step | Action |
|------|--------|
| 1 | The user navigates to the inventory page. |
| 2 | The platform aggregates inventory across all enabled integrations the user is permitted to see, applies the linking rules, and renders a paginated list. |
| 3 | The user filters by group, source integration, status, fact value, or free-text. |
| 4 | The platform applies the filters using server-side predicate push-down where the source supports it. |
| 5 | The user selects a node. The platform navigates to the node detail page. |
| 6 | The detail page loads sections for every integration type the integrations covering this node provide. Sections are loaded in parallel; each indicates its source(s) and data freshness. |
| 7 | Sections from healthy sources render immediately. Sections from unhealthy sources render with cached data and staleness markers. Sections backed by no source (because the relevant integrations are disabled) do not appear. |

| ID | Requirement |
|----|-------------|
| `FLOW-001` | The system **MUST** complete steps 1–2 within 2 seconds at the target scale of 10,000 nodes given a healthy primary inventory source. |
| `FLOW-002` | Step 6 sections **MUST** load independently — a slow Reports section **MUST NOT** delay the rendering of Facts, Configuration, or any other section. |
| `FLOW-003` | The detail page **MUST** present all and only the sections corresponding to enabled integration capabilities. |

## 13.2 Flow 2 — Remote command execution

**Actor:** DevOps / SRE

**Pre-conditions:** user authenticated; user has `*:command:execute` permission for the chosen integration; targets are reachable.

| Step | Action |
|------|--------|
| 1 | The user selects one or more targets (single node, multiple nodes, group, or filter expression). |
| 2 | The user chooses an execution integration (Bolt, Ansible, SSH, AWX, etc.). |
| 3 | The user enters a command, selects a task/playbook/plan from the catalog, or selects a previous execution to re-run. |
| 4 | The platform validates: targets are reachable through the chosen integration; the user has permission for this action on this integration; the command/task/playbook is on the user's allowlist. |
| 5 | If validation fails, the platform reports which check failed (RBAC, allowlist, target reachability) with an actionable message. |
| 6 | On validation success, the platform invokes the integration. The execution stream begins. |
| 7 | Output appears in the UI in real time, attributed per target. |
| 8 | If the user disconnects mid-execution, the server-side execution continues; on reconnect, the UI resumes from the last received position. |
| 9 | On completion, the full transcript is stored. One Journal Entry per target Node is created. The execution is added to the user's history. |
| 10 | The user **MAY** re-execute the same artifact later with one click. |

| ID | Requirement |
|----|-------------|
| `FLOW-101` | Step 4 validation **MUST** complete before any external invocation occurs. |
| `FLOW-102` | Step 7 streaming output **MUST** appear in the UI within 200 ms of generation on the target node, network latency permitting. |
| `FLOW-103` | Step 8 reconnection **MUST NOT** result in lost output. |
| `FLOW-104` | Step 9 transcript persistence **MUST** complete before the execution is removed from in-memory streaming state. |

## 13.3 Flow 3 — VM provisioning

**Actor:** infrastructure engineer

**Pre-conditions:** at least one provisioning-capable integration is configured and healthy; user has the relevant `*:vm:create` (or similar) permission.

| Step | Action |
|------|--------|
| 1 | The user navigates to the provisioning page. |
| 2 | The platform displays available provisioning integrations and their resource options (templates, sizes, networks, regions). |
| 3 | The user fills the provisioning form (integration-specific parameters). The form is generated from the integration's resource discovery output. |
| 4 | The platform validates parameters and permissions. |
| 5 | On submission, the platform invokes the integration's create operation. |
| 6 | The platform reports state transitions (pending → creating → running → ready) in real time. |
| 7 | On completion, the new node is registered with the integration's inventory source and appears in unified inventory within one inventory refresh cycle. |
| 8 | A Journal Entry records the provisioning action, sourced from the upstream tool's real-time event log. |
| 9 | The user **MAY** immediately initiate fact gathering, command execution, or further provisioning lifecycle actions against the new node. |

| ID | Requirement |
|----|-------------|
| `FLOW-201` | Step 7 inventory appearance **MUST** occur within one inventory refresh cycle (default 5 minutes; configurable). |
| `FLOW-202` | Step 8 Journal Entry **MUST** be sourced from the upstream tool's API event log via realtime queries, not from local state inference. |
| `FLOW-203` | Step 9 follow-up actions **MUST** succeed without requiring a manual refresh — the new node is fully addressable as soon as inventory contains it. |

## 13.4 Flow 4 — Graceful degradation

**Actor:** infrastructure engineer (in the middle of an incident)

**Pre-conditions:** multiple integrations are enabled, including PuppetDB.

| Step | Action |
|------|--------|
| 1 | PuppetDB becomes unreachable (network blip, maintenance window, deployment). |
| 2 | The platform's health check detects the failure within the configured interval and marks Puppet's affected capabilities as unhealthy. |
| 3 | Inventory page continues to load — nodes from other sources (Ansible, SSH, Proxmox, AWS, Azure) appear normally. |
| 4 | Nodes known *only* via PuppetDB are presented from the cache with a staleness indicator showing the last successful fetch. |
| 5 | The user can still execute commands via Bolt, Ansible, or SSH against any reachable node. |
| 6 | Facts, configuration, events, reports — all PuppetDB-backed sections show a degraded-state banner with the diagnostic and last-success time. |
| 7 | The integration status dashboard shows PuppetDB as unhealthy, with a clear, actionable diagnostic. |
| 8 | When PuppetDB recovers, the circuit breaker probes detect recovery and resume normal operation. Caches refresh in the background. |
| 9 | The staleness markers are cleared as live data returns. |

| ID | Requirement |
|----|-------------|
| `FLOW-301` | Step 3 inventory rendering **MUST** complete within the same latency envelope as a fully-healthy state — degraded state must not slow down the healthy parts. |
| `FLOW-302` | Step 5 execution **MUST** function unaffected by Puppet's outage. |
| `FLOW-303` | Step 8 recovery **MUST** be automatic — no administrator intervention required to resume normal operation. |

## 13.5 Flow 5 — Puppet run with changes → journal

**Actor:** the Puppet agent on a node, plus an operator viewing the journal afterward

**Pre-conditions:** Puppet integration is healthy; PuppetDB is receiving reports.

| Step | Action |
|------|--------|
| 1 | A Puppet agent runs on a node and applies a catalog. The run causes three resources to change. |
| 2 | The agent submits the report to PuppetDB. |
| 3 | On the next data refresh (or via push notification, where configured), Vigil detects the new report. |
| 4 | The platform extracts change events from the report — three events for the three changed resources. No-op resources (unchanged) **MUST NOT** produce events. |
| 5 | Three external journal entries are normalized for display, attributed to Puppet, and grouped under the report ID. They are not persisted locally; PuppetDB remains the source of truth. |
| 6 | The operator viewing the node's journal sees the three changes grouped together, with drill-down available to the full report and per-resource detail. |
| 7 | A subsequent Puppet run that produces no changes (steady state) **MUST NOT** create journal entries. |

| ID | Requirement |
|----|-------------|
| `FLOW-401` | Step 4 event extraction **MUST** filter out no-op events. |
| `FLOW-402` | Step 5 grouping **MUST** preserve the report ID so the entries appear together in the UI. |
| `FLOW-403` | Step 7 silence on no-op runs **MUST** be the default behavior. |

## 13.6 Flow 6 — Large-scale inventory search

**Actor:** infrastructure engineer

**Pre-conditions:** 5,000+ nodes across heterogeneous sources.

| Step | Action |
|------|--------|
| 1 | The user enters a fact-based search: "all nodes where `os.distro.codename = jammy`". |
| 2 | The platform identifies which sources can answer this query server-side (PuppetDB via PQL, AWS via tag/AMI filters where applicable) and which cannot. |
| 3 | For server-filterable sources, the platform issues filtered queries. |
| 4 | For non-filterable sources, the platform queries cached facts and applies the filter client-side. |
| 5 | Results are paginated and returned progressively — fast sources first. The UI updates as results from each source land. |
| 6 | The user navigates the paginated result set without blocking on slow sources. |
| 7 | Sources that exceed the per-source timeout are reported as "no results in time" with a "retry" affordance, but **MUST NOT** block the rest of the result set. |

| ID | Requirement |
|----|-------------|
| `FLOW-501` | Step 3 server-side filtering **MUST** be used wherever the source supports it — the platform **MUST NOT** materialize 10,000-node fact sets client-side for filterable queries. |
| `FLOW-502` | Step 5 progressive rendering **MUST** be the default — the UI **MUST NOT** wait for all sources to complete. |
| `FLOW-503` | Step 7 timeout handling **MUST** be visible to the user and **MUST NOT** silently omit results. |

## 13.7 Flow 7 — Monitoring state change → journal

**Actor:** monitoring system + the on-call responder reviewing later

**Pre-conditions:** a monitoring integration (e.g., Icinga) is configured.

| Step | Action |
|------|--------|
| 1 | A monitored check transitions from OK to CRITICAL on a node. |
| 2 | The monitoring source reports the transition (via push if supported, otherwise via the next short-poll). |
| 3 | The platform creates a Journal Entry: "Monitoring state changed: OK → CRITICAL (check: disk_usage)" attributed to the monitoring integration. |
| 4 | The node's monitoring section in the UI updates to show the CRITICAL state. |
| 5 | When the check recovers (CRITICAL → OK), another Journal Entry is created. |
| 6 | Steady-state observations (the check evaluates to CRITICAL again 60 seconds later, still CRITICAL) **MUST NOT** generate additional entries. |

| ID | Requirement |
|----|-------------|
| `FLOW-601` | Step 3 entry creation **MUST** distinguish state transitions from steady-state evaluations. |
| `FLOW-602` | Step 6 silence on steady-state **MUST** be the default. |
| `FLOW-603` | The platform **MUST** record the duration of CRITICAL state when the recovery entry is created (for incident-summary purposes). |

## 13.8 Additional flows worth supporting

These flows are not numbered as primary scenarios but **MUST** be supported by the system. They are listed here for completeness.

- **Manual journal note**: an operator adds a free-text note to a node's journal during an incident, tagged with `incident-2026-04-15`.
- **Hiera key resolution**: an operator inspects how a Hiera key resolves for a specific node, seeing the full hierarchy chain and the contributing level.
- **Catalog diff between environments**: an operator compares a node's `production` and `staging` catalogs to verify a change is propagating correctly.
- **Group-targeted execution**: an operator selects an Ansible group and runs an ad-hoc command, seeing per-target streaming output for all 50 hosts in the group.
- **Re-run a recent execution**: an operator clicks "re-run" on a five-minute-old execution to verify a fix; the same command runs against the same targets.
- **Provision a development VM, configure it via Puppet, run a smoke test**: a single user action sequence touching three integrations: Proxmox creates the VM, the new node's certname appears in PuppetDB on first agent run, an SSH or Bolt execution runs the smoke test.
- **External authentication first login**: a user authenticates via SAML, the platform JIT-creates the user, group memberships are mapped to roles, the user lands on the inventory page with permissions correctly applied.
- **Code Manager deployment**: an administrator triggers a Puppet code deploy via webhook from Vigil; the deployment outcome is reported back; cached catalog data invalidates for the affected environment.
- **MCP query from an AI assistant**: an external AI agent queries the MCP server for a node's journal, receives a token-efficient structured response, and produces a summary.

| ID | Requirement |
|----|-------------|
| `FLOW-701` | Each additional flow above **MUST** be supported in the released system. The numbered flows define the highest-priority scenarios; the additional flows expand the coverage. |

---

[← Previous: Data Model](12-data-model.md) | [Next: Real-time & Streaming →](14-realtime-streaming.md)

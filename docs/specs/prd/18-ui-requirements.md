# 18. User Interface Requirements

The user interface is the system's primary surface. It is web-based, multi-user, and built around node-centric workflows. This section specifies the information architecture, the per-section behavior, and the cross-cutting UI contracts that bind the system together.

## 18.1 Foundational UI principles

| ID | Requirement |
|----|-------------|
| `UI-001` | The UI **MUST** be driven by enabled integrations — disabled integrations produce zero UI footprint (no tabs, no sections, no menu items). |
| `UI-002` | Enabled but failing integrations **MUST** show their sections with degradation indicators rather than disappearing. |
| `UI-003` | The UI **MUST** present source attribution everywhere data is shown — the user **MUST** be able to ask "where did this come from?" and receive a precise answer. |
| `UI-004` | The UI **MUST** be operable at the target scale of 10,000 nodes without slowdown perceptible to the user. Pagination, virtualization, and progressive loading **MUST** be applied consistently. |
| `UI-005` | The UI **MUST** be responsive to viewport size, supporting at minimum desktop and laptop sizes. Mobile is not a primary target but the UI **MUST NOT** be unusable on a tablet. |
| `UI-006` | The UI **MUST** be navigable via keyboard. Mouse-only paths to important actions are forbidden. |
| `UI-007` | The UI **MUST** meet the accessibility baseline of WCAG 2.1 Level AA for color contrast, focus indication, and semantic structure. |

## 18.2 Information architecture

The UI's top-level structure **MUST** include the following sections:

| Section | Purpose |
|---------|---------|
| **Inventory** | Aggregated, filterable, paginated node list. Entry point for most flows. |
| **Groups** | Group browser, with linked groups across sources. |
| **Journal / Timeline** | Global event timeline across all nodes. Per-node timelines are reachable from each node. |
| **Executions** | Execution history and re-execution. |
| **Provisioning** | New-VM/container creation, by integration. |
| **Reports** | Cross-node report list with drill-down. |
| **Health** | Integration status dashboard. |
| **Settings** | Configuration: integrations, users, roles, linking rules, allowlists, AI keys. |

| ID | Requirement |
|----|-------------|
| `UI-101` | The top-level navigation **MUST** show only the sections relevant to the user's permissions. Sections the user cannot access **MUST NOT** appear. |
| `UI-102` | Navigation **MUST** be consistent across the application — the same primary navigation appears on every page. |
| `UI-103` | The current section, the current node (when in a node detail), and the current view **MUST** be reflected in the URL. Direct URL access **MUST** restore the corresponding state. |
| `UI-104` | Every detail page **MUST** be deep-linkable for sharing. |

## 18.3 Inventory page

| ID | Requirement |
|----|-------------|
| `UI-201` | The inventory page **MUST** present a paginated list of nodes, default sorted by name (ascending). |
| `UI-202` | Each row **MUST** display: node name, primary identity attribute, source attribution (icons or labels for each contributing integration), status, group membership (compact), last-seen timestamp. |
| `UI-203` | The inventory page **MUST** support filters: by source integration, by group, by status, by fact value (key-value match), by free-text search. |
| `UI-204` | The filter UI **MUST** allow combining multiple filters with AND semantics. Multi-value filters within a single dimension **MUST** combine with OR semantics. |
| `UI-205` | Search **MUST** be debounced (search-as-you-type with a small delay) to avoid spamming server requests. |
| `UI-206` | Filters and search state **MUST** be reflected in the URL so they can be shared and bookmarked. |
| `UI-207` | The inventory page **MUST** indicate when a result set is partial due to source unavailability or timeout — "X of Y sources responded; results may be incomplete." |
| `UI-208` | The inventory page **MUST** support bulk selection for execution and (where applicable) provisioning lifecycle actions. |

## 18.4 Node detail page

The node detail page is the application's most data-rich screen. It aggregates data from all integration types covering the node.

| Section | Source type | Display behavior |
|---------|------------|------------------|
| Identity & Status | Inventory | Source attribution per identity attribute; group membership; current status per source |
| System Facts | Facts | Tabular, hierarchically organized, source-attributed; per-fact-key reconciled view with drill-in to per-source values |
| Health & Monitoring | Monitoring | Current check status; live-updating; alerts list |
| Configuration | Configuration | Hiera browse with key resolution; catalog browse; environment selector; catalog diff link |
| Journal / Timeline | Events (extracted from all journal-contributing types) | Filterable, paginated; group-linked entries; drill-down to source |
| Run History | Reports | Recent reports with status; trend visualization; drill into specific report |
| Deployments | Deployment | Per-application version history with deploy timestamps |
| Execute | Remote Execution | Command/task input; target = this node by default; live streaming output |
| Lifecycle | Provisioning | Start/stop/reboot/etc., only for nodes managed by a provisioning integration |

| ID | Requirement |
|----|-------------|
| `UI-301` | The node detail page **MUST** present all and only the sections corresponding to integration capabilities covering the current node. |
| `UI-302` | Sections **MUST** be loaded in parallel; one slow section **MUST NOT** delay the rendering of others. |
| `UI-303` | Each section **MUST** show its data freshness — last-fetched timestamp or live indicator. |
| `UI-304` | Each section **MUST** show its source — which integration(s) contributed the displayed data. |
| `UI-305` | A failing section **MUST** display a degraded-state banner with the diagnostic and a "retry" affordance. The rest of the page **MUST** remain functional. |
| `UI-306` | The user **MUST** be able to deep-link to specific tabs / sections of the node detail page. |
| `UI-307` | The node detail page **MUST** show the user's permitted actions only. Actions not permitted by RBAC **MUST NOT** appear. |

## 18.5 Journal / timeline UI

| ID | Requirement |
|----|-------------|
| `UI-401` | The journal **MUST** be presented as a chronologically ordered list (default newest first). |
| `UI-402` | Entries from the same source-defined group (e.g., a Puppet report) **MUST** be visually grouped together. |
| `UI-403` | Filters available: type, source integration, time range, severity, free-text search across summary content. |
| `UI-404` | Filters **MUST** be combinable. |
| `UI-405` | Each entry **MUST** show: timestamp, source icon, type, summary, and (when available) a "view source" affordance leading to the underlying report or execution transcript. |
| `UI-406` | Manual journal notes **MUST** be visually distinct (e.g., distinct color or icon) and **MUST** show the authoring user. |
| `UI-407` | Vigil-originated journal entries (executions, manual notes) **MUST** appear in the timeline immediately upon creation without requiring a manual refresh. External-source entries **MUST NOT** auto-refresh by default — they are fetched on page load or explicit user action per `JRN-205`/`JRN-206`. |
| `UI-408` | The user **MUST** be able to add a manual note from the journal view, scoped to the current node or group. |

## 18.6 Execution UI

| ID | Requirement |
|----|-------------|
| `UI-501` | The execution UI **MUST** be reachable from: the node detail's Execute section; the inventory's bulk-select action; the dedicated Executions page (re-run from history). |
| `UI-502` | The execution form **MUST** allow choosing: execution integration, target set, artifact (command, task, playbook, plan), parameters. |
| `UI-503` | Where the integration provides task/playbook metadata, parameter inputs **MUST** be auto-generated with field types, validation, and required indicators. |
| `UI-504` | The execution form **MUST** show, before submission: the target set (with explicit confirmation if > 50 nodes), the artifact, and the per-target permission validation result. |
| `UI-505` | Post-submission, the live output view **MUST** display: per-target streaming output with attribution, current execution status, abort affordance. |
| `UI-506` | The live output view **MUST** support filtering output by target (show only this target's output) and by output stream (stdout/stderr). |
| `UI-507` | Completed executions **MUST** display: full per-target transcript, exit status per target, duration per target, parameters, initiating user, "re-run" affordance. |
| `UI-508` | The execution history view **MUST** support filtering by user, integration, time range, status. |

## 18.7 Provisioning UI

| ID | Requirement |
|----|-------------|
| `UI-601` | The provisioning page **MUST** display the available provisioning integrations and a "Create" entry point per integration. |
| `UI-602` | Each integration's provisioning form **MUST** be generated from the integration's resource discovery output — templates, sizes, networks, regions. |
| `UI-603` | The form **MUST** validate selections (e.g., the chosen subnet belongs to the chosen VPC) before allowing submission. |
| `UI-604` | On submission, the user **MUST** see a progress view with state transitions reported in real time. |
| `UI-605` | On completion, the user **MUST** be offered direct navigation to the new node's detail page. |
| `UI-606` | The provisioning page **MUST** show the user's recent provisioning actions, with status and link-through. |

## 18.8 Health / status dashboard

| ID | Requirement |
|----|-------------|
| `UI-701` | The health dashboard **MUST** display every enabled integration with: overall status, per-capability status, last-successful-call timestamp per capability, last-failure detail per capability. |
| `UI-702` | The dashboard **MUST** allow administrators to: trigger manual health check, refresh credentials, reload configuration, disable/re-enable integration. |
| `UI-703` | The dashboard **MUST** show health history (e.g., last 24 hours) so flapping is visible. |
| `UI-704` | The dashboard **MUST** show platform-level health: database connectivity, cache health, queue depth, current load. |

## 18.9 Settings / administration UI

| ID | Requirement |
|----|-------------|
| `UI-801` | Settings **MUST** be organized by domain: Integrations, Users, Roles, Linking Rules, Command Allowlists, Authentication, Audit Trail, AI Configuration, Retention. |
| `UI-802` | Each integration's configuration page **MUST** present the plugin's declared schema with field-level help, validation, and a "test connection" action. |
| `UI-803` | The "test connection" action **MUST** exercise a low-cost call against each declared sub-system and report per-sub-system success/failure with diagnostic detail. |
| `UI-804` | Sensitive fields **MUST** be displayed redacted by default with an "edit" affordance to replace (not view) the value. |
| `UI-805` | Configuration changes **MUST** be confirmable before save, with a clear summary of what changes. |
| `UI-806` | The audit trail UI **MUST** support filtering by user, action type, target, time range, and **MUST** support export. |

## 18.10 Cross-cutting UI behaviors

### 18.10.1 Loading states

| ID | Requirement |
|----|-------------|
| `UI-901` | Loading states **MUST** be visible for any operation taking longer than 200 ms. |
| `UI-902` | Loading states **MUST** be specific — "loading inventory from PuppetDB" beats "loading" — when the platform knows what it's loading. |
| `UI-903` | Loading states **MUST NOT** block unrelated parts of the UI. Partial loading is the default. |

### 18.10.2 Empty states

| ID | Requirement |
|----|-------------|
| `UI-1001` | Empty states **MUST** include guidance: "no nodes match your filter — clear filter or adjust criteria." |
| `UI-1002` | First-run empty states (no integrations configured) **MUST** include direct links to setup. |
| `UI-1003` | Empty states **MUST NOT** confuse "no data" with "data unavailable" — they read differently. |

### 18.10.3 Error states

| ID | Requirement |
|----|-------------|
| `UI-1101` | Error states **MUST** be inline (within the affected section) where possible — they **MUST NOT** replace the whole page. |
| `UI-1102` | Error messages **MUST** follow [section 15](15-error-handling.md) — actionable, non-technical, with a remediation hint. |
| `UI-1103` | Errors **MUST** include a "retry" affordance where retry is sensible, and a "report" affordance where escalation is sensible. |

### 18.10.4 Confirmation flows

| ID | Requirement |
|----|-------------|
| `UI-1201` | Destructive actions (terminate VM, delete user, revoke token) **MUST** require confirmation. |
| `UI-1202` | The confirmation prompt **MUST** name the specific target — "terminate `web-prod-04`?" not "terminate this VM?". |
| `UI-1203` | Bulk destructive actions affecting more than 10 targets **MUST** require typed confirmation (e.g., type the integration name). |
| `UI-1204` | Confirmation prompts **MUST** show what permission is being exercised so the user understands the consequence. |

### 18.10.5 Source attribution display

| ID | Requirement |
|----|-------------|
| `UI-1301` | Source attribution **MUST** be visible on every screen where data is displayed: row-level on lists, header-level on detail pages, per-cell on tables of facts. |
| `UI-1302` | Source attribution **MUST** be expressed compactly by default (icons, short labels) with full detail available on hover or click. |
| `UI-1303` | Where multiple sources contribute to a single value, the UI **MUST** allow drill-in to per-source values. |

## 18.11 Real-time UI behaviors

| ID | Requirement |
|----|-------------|
| `UI-1401` | The UI **MUST** indicate connection state — when the connection to the server is lost, a visible disconnected indicator appears. |
| `UI-1402` | On reconnection, the UI **MUST** sync state without requiring a full reload. |
| `UI-1403` | Live-updating sections (monitoring, journal, execution streams) **MUST** indicate they are live-updating versus snapshot. |
| `UI-1404` | The user **MUST** be able to pause live updates per section (e.g., to inspect a moment in a fast-moving log without losing context). |

## 18.12 Internationalization and time

| ID | Requirement |
|----|-------------|
| `UI-1501` | All timestamps **MUST** be displayed with timezone disambiguation. The user **MAY** select preferred timezone or default to UTC. |
| `UI-1502` | Relative time displays ("3 minutes ago") **SHOULD** be available with absolute timestamps shown on hover. |
| `UI-1503` | The system **MAY** support multiple display languages in the future; the architecture **MUST NOT** preclude this. |

---

[← Previous: AI-Assisted Features](17-ai-features.md) | [Next: Non-Functional Requirements →](19-non-functional-requirements.md)

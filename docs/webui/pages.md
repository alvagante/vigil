# Vigil — Web UI Pages Reference

**Derived from:** `docs/specs/prd/18-ui-requirements.md`, `docs/specs/design/09-liveview-ui.md`
**Purpose:** Quick reference of all expected pages, their content, and internal structure.

---

## Consistency notes

The PRD and design docs are aligned. Two minor observations:

1. The design introduces a **Dashboard** landing page (`/`) not explicitly specified in the PRD's information architecture table — but consistent with the PRD's intent (the inventory is the primary entry point; the dashboard provides a summary before drilling in).
2. The design's `/settings/*path` catch-all covers all nine settings domains listed in `UI-801`. The admin-specific routes (`/settings/integrations`, `/settings/users`, etc.) are explicit for RBAC gating; remaining domains (Allowlists, Authentication, AI Configuration, Retention) route through the generic `SettingsLive` module.

No contradictions between PRD and design were found.

---

## Page inventory

| # | Page | Route | LiveView module |
|---|------|-------|-----------------|
| 1 | Dashboard | `/` | `DashboardLive` |
| 2 | Inventory | `/inventory` | `InventoryLive` |
| 3 | Node Detail | `/inventory/node/:id(/:tab)` | `NodeDetailLive` |
| 4 | Groups | `/groups` | `GroupsLive` |
| 5 | Group Detail | `/groups/:id` | `GroupDetailLive` |
| 6 | Journal / Timeline | `/journal` | `GlobalTimelineLive` |
| 7 | Executions | `/executions` | `ExecutionsIndexLive` |
| 8 | Execution Detail | `/executions/:id` | `ExecutionLive` |
| 9 | New Execution | `/executions/new` | `ExecutionSubmitLive` |
| 10 | Provisioning | `/provisioning` | `ProvisioningIndexLive` |
| 11 | Provisioning Form | `/provisioning/:integration` | `ProvisioningFormLive` |
| 12 | Provisioning Operation | `/provisioning/op/:id` | `ProvisioningOperationLive` |
| 13 | Reports | `/reports` | `ReportsLive` |
| 14 | Report Detail | `/reports/:id` | `ReportDetailLive` |
| 15 | Health Dashboard | `/health` | `HealthDashboardLive` |
| 16 | Settings | `/settings/*path` | `SettingsLive` |

---

## 1. Dashboard (`/`)

**Purpose:** Landing page after login. High-level operational summary.

| Section | Content |
|---------|---------|
| Integration health summary | Card per enabled integration showing overall status (healthy/degraded/unhealthy) |
| Recent activity | Last N journal entries across all nodes |
| Execution summary | Active/recent executions with status |
| Inventory stats | Total nodes, nodes by status, source coverage |

No tabs. Single-page overview with links into each top-level section.

---

## 2. Inventory (`/inventory`)

**Purpose:** Aggregated, filterable, paginated node list. Primary entry point for node-centric workflows. (`UI-201`–`UI-208`)

| Section | Content |
|---------|---------|
| Filter bar | Source integration, group, status, fact-value query, free-text search (debounced 300ms) |
| Source attribution summary | Which sources responded, which are stale/down |
| Bulk actions bar | Execute on selected, clear selection |
| Node table | Columns: name, primary identity, source badges, status, groups (compact), last seen |
| Pagination | Cursor-based prev/next |

Filters and search state reflected in URL for bookmarking/sharing (`UI-206`).

---

## 3. Node Detail (`/inventory/node/:id/:tab`)

**Purpose:** Most data-rich page. Aggregates all integration types covering a single node. (`UI-301`–`UI-307`)

Tabs are **dynamic** — only those corresponding to integration capabilities active on this node are shown. Each tab loads independently (parallel async).

| Tab | Condition | Content |
|-----|-----------|---------|
| **Overview** | Always | Identity attributes, source attribution, group memberships, status per source, linking decision |
| **Facts** | ≥1 Facts-capable integration covers node | Hierarchical key/value table, per-key source attribution, reconciled view with drill-in to per-source values |
| **Configuration** | ≥1 Configuration-capable integration | Hiera key browser with hierarchy resolution, catalog resource browser, environment selector, catalog diff link |
| **Journal** | Always (local entries + external events) | Per-node timeline, filterable by type/source/severity/time-range, grouped entries, manual note input, back-references to reports/executions |
| **Reports** | ≥1 Reports-capable integration | Recent reports with status, trend visualization, drill-in to per-resource detail, noop/dry-run indicator |
| **Monitoring** | ≥1 Monitoring-capable integration | Current check statuses (live-updating), alerts list with severity and acknowledgement state |
| **Deployments** | ≥1 Deployment-capable integration | Per-application version history with deploy timestamps and actors |
| **Execute** | ≥1 Remote-Execution-capable integration + user has permission | Command/task input, target defaults to this node, integration selector, live streaming output |
| **Lifecycle** | ≥1 Provisioning-capable integration manages this node | Start/stop/reboot/suspend/resume/destroy buttons (RBAC-gated), state indicator |

Each tab shows: data freshness marker, source attribution, degraded-state banner on failure with retry affordance.

---

## 4. Groups (`/groups`)

**Purpose:** Browse and search groups across all sources. (`INV-301`–`INV-304`)

| Section | Content |
|---------|---------|
| Filter/search | By source, by name, free-text |
| Group list | Name, source attribution (badges for each contributing integration), member count, hierarchy indicator |
| Linked group indicator | Shows when a group is merged from multiple sources |

---

## 5. Group Detail (`/groups/:id`)

**Purpose:** Inspect a single group's membership and metadata.

| Section | Content |
|---------|---------|
| Header | Group name, source attribution, hierarchy path (parent/children per source) |
| Members table | Paginated node list (same columns as inventory), filterable |
| Metadata | Source-specific attributes (Ansible group_vars, AWS tag values, etc.) |
| Actions | Execute on group members, add manual journal note scoped to group |

---

## 6. Journal / Timeline (`/journal`)

**Purpose:** Global event timeline across all nodes. (`UI-401`–`UI-408`, `JRN-101`–`JRN-103`, `JRN-201`–`JRN-207`)

| Section | Content |
|---------|---------|
| Filter bar | Type, source integration, severity, time-range picker, node/group filter, free-text (client-side on loaded entries per `JRN-103`) |
| Entry list | Chronological (newest first), each showing: timestamp, source icon, type, severity, summary |
| Grouped entries | Entries from same source-defined group (e.g., Puppet report) visually grouped (`JRN-005`) |
| Manual notes | Visually distinct (different icon/color), showing authoring user (`JRN-304`, `UI-406`) |
| Entry expansion | Click to expand: structured details, back-references to report/execution (`JRN-401`–`JRN-403`) |
| Add note | Manual note input scoped to a node or group, supports free-text with optional structured tags (`JRN-301`–`JRN-305`) |
| Auto-refresh toggle | **Off by default** (`JRN-205`). Opt-in with selectable interval; when enabled, UI displays notice that periodic upstream API calls are being made (`JRN-206`) |
| Source loading indicators | Per-source status showing which are still loading, which have responded, which have failed (`JRN-207`) |

**Data sourcing model:**

- **Does NOT auto-refresh by default.** External events are fetched on-demand from source tool APIs when the user loads/navigates to the page or clicks a manual refresh button (`JRN-205`).
- **Vigil-originated entries** (executions, manual notes) are persisted locally and appear via PubSub without upstream calls (`JRN-203`, `UI-407`). These live-update immediately.
- **External events** (Puppet reports, monitoring transitions, provisioning lifecycle, deployments) are fetched from the source tool's API at page load. The source tool remains the single source of truth — Vigil does NOT store copies (`JRN-202`).
- **Progressive rendering:** local entries appear immediately; external source results appear as each API responds (`JRN-207`).

---

## 7. Executions (`/executions`)

**Purpose:** Execution history and re-execution entry point. (`UI-508`, `EXEC-201`–`EXEC-204`)

| Section | Content |
|---------|---------|
| Filter bar | By user, integration, time range, status |
| Execution list | Columns: timestamp, user, integration, artifact summary, target count, status, duration |
| Row actions | View detail, re-run |

---

## 8. Execution Detail (`/executions/:id`)

**Purpose:** View a live or completed execution with streaming output. (`UI-505`–`UI-507`)

| Section | Content |
|---------|---------|
| Header | Artifact, integration, initiating user, start time, overall status |
| Target summary | Per-target status chips (running/completed/failed) |
| Streaming output | Per-target terminal output with attribution; filterable by target and stream (stdout/stderr) |
| Controls | Pause updates toggle, abort button (if running) |
| Completion summary | Exit status per target, duration per target, parameters used |
| Re-run button | Opens new execution form pre-filled from this execution |

---

## 9. New Execution (`/executions/new`)

**Purpose:** Submit a new execution. (`UI-501`–`UI-504`)

| Section | Content |
|---------|---------|
| Target selection | Single node search, select from inventory filter, paste list, select group |
| Integration selector | Choose execution-capable integration |
| Artifact selection | Command input (ad-hoc), or task/playbook/plan picker from integration's catalog |
| Parameter form | Auto-generated fields from integration's discovery output (types, validation, required indicators) |
| Pre-submission review | Target set, artifact, RBAC validation result, allowlist check result, confirmation for >50 targets |

---

## 10. Provisioning (`/provisioning`)

**Purpose:** Entry point for VM/container creation and recent provisioning history. (`UI-601`, `UI-606`)

| Section | Content |
|---------|---------|
| Available integrations | Card per provisioning-capable integration with "Create" button |
| Recent operations | User's recent provisioning actions with status and link-through |

---

## 11. Provisioning Form (`/provisioning/:integration`)

**Purpose:** Integration-specific provisioning form. (`UI-602`–`UI-603`)

| Section | Content |
|---------|---------|
| Resource options | Fields generated from integration's resource discovery: templates/images, sizes/flavors, networks/subnets, storage, regions |
| Validation | Cross-field validation (e.g., subnet belongs to chosen VPC) |
| Submit | Creates the resource after validation |

---

## 12. Provisioning Operation (`/provisioning/op/:id`)

**Purpose:** Real-time progress view for an in-flight provisioning action. (`UI-604`–`UI-605`)

| Section | Content |
|---------|---------|
| State transitions | Real-time progress: pending → creating → running → ready |
| Completion | Link to new node's detail page on success |
| Error | Diagnostic and retry affordance on failure |

---

## 13. Reports (`/reports`)

**Purpose:** Cross-node report list with drill-down. (`TYPE-RPT-005`)

| Section | Content |
|---------|---------|
| Filter bar | By node, integration, time range, status, mode (noop/normal) |
| Report list | Columns: timestamp, node, integration, status, summary metrics, mode |
| AI features | "Weekly change summary", "Nodes at risk", "Unused resources" buttons (when AI configured) |

---

## 14. Report Detail (`/reports/:id`)

**Purpose:** Full report inspection. (`TYPE-RPT-001`–`TYPE-RPT-006`)

| Section | Content |
|---------|---------|
| Header | Node, integration, environment/scope, start/end timestamps, mode |
| Summary metrics | Counts (changed, failed, skipped, no-op), durations |
| Phase timings | Where available (e.g., Puppet facts/catalog/apply phases) |
| Resource/finding detail | Expandable per-resource entries with old/new values, file/line references |
| Log entries | Severity-tagged log lines from the run |
| AI feature | "Analyze recent failures" button (when AI configured) |

---

## 15. Health Dashboard (`/health`)

**Purpose:** Integration status and platform health. (`UI-701`–`UI-704`, `HEALTH-101`–`HEALTH-104`)

| Section | Content |
|---------|---------|
| Integration cards | Per-integration: overall status, per-capability status, last-successful-call timestamp, last-failure detail |
| Admin actions | Force health check, flush caches, reload config, disable/re-enable integration |
| Health history | Per-integration timeline (last 24h) showing flapping |
| Platform health | Database connectivity, cache health, queue depth, current load |

Live-updating via PubSub subscription to `integration_health:all`.

---

## 16. Settings (`/settings/*path`)

**Purpose:** System configuration and administration. (`UI-801`–`UI-806`)

Organized as sub-pages by domain. Admin-only routes have additional RBAC gating.

| Sub-page | Route suffix | Content |
|----------|--------------|---------|
| **Integrations** | `/settings/integrations` | List of configured integrations; per-integration config form (plugin-declared schema, field-level help, validation, "test connection" action); sensitive fields redacted |
| **Users** | `/settings/users` | User list, create/disable/enable/delete, role assignments, token management, auth source display |
| **Roles** | `/settings/roles` | Role list, permission editor (action × integration scope × target scope), default roles |
| **Linking Rules** | `/settings/linking` | Identity attribute precedence, per-source confidence weights, manual override list, unresolved conflicts queue |
| **Command Allowlists** | `/settings/allowlists` | Per-integration and per-role allowlists/blocklists for commands, tasks, playbooks |
| **Authentication** | `/settings/auth` | Local auth settings (complexity, lockout), external IdP configuration (SAML, OIDC, LDAP), group-to-role mappings, default role for unmapped groups |
| **Audit Trail** | `/settings/audit` | Filterable log (by user, action type, target, time range), export capability |
| **AI Configuration** | `/settings/ai` | Provider setup (API keys via secrets-aware mechanism), per-feature provider selection, per-feature enable/disable, global AI kill switch, token budget caps, usage dashboard |
| **Retention** | `/settings/retention` | Retention policies for: execution transcripts, manual journal notes, audit trail; manual purge (admin-only with confirmation) |

All configuration changes require confirmation before save with a summary of what changes (`UI-805`).

---

## Cross-cutting behaviors (all pages)

| Behavior | Reference | Implementation |
|----------|-----------|----------------|
| Loading states | `UI-901`–`UI-903` | Skeleton/spinner after 200ms; specific labels ("loading inventory from PuppetDB") |
| Empty states | `UI-1001`–`UI-1003` | Guidance text; first-run links to setup; "no data" vs "data unavailable" distinction |
| Error states | `UI-1101`–`UI-1103` | Inline within affected section; actionable message; retry/report affordance |
| Confirmation flows | `UI-1201`–`UI-1204` | Named-target confirmation; typed confirmation for bulk >10 targets |
| Source attribution | `UI-1301`–`UI-1303` | Row-level badges on lists; header-level on details; per-cell on fact tables; drill-in on click |
| Connection state | `UI-1401`–`UI-1404` | Disconnected banner; auto-rehydration on reconnect; live indicator; pause toggle |
| Timestamps | `UI-1501`–`UI-1502` | Timezone-disambiguated; relative with absolute on hover |
| Navigation | `UI-101`–`UI-104` | RBAC-filtered; consistent primary nav; URL reflects state; deep-linkable |
| Accessibility | `UI-007` | WCAG 2.1 AA; semantic HTML; keyboard navigable; aria-live regions; focus management |

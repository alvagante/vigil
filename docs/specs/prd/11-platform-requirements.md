# 11. Platform Requirements

This section specifies cross-cutting platform requirements. These are the concerns that span integrations: unified inventory, the remote-execution platform, the journal, authentication, authorization, health, resilience, performance, caching, and configuration. Where an integration's requirements interact with these, the integration spec defers to this section.

## 11.1 Unified inventory

The unified inventory is the platform's reconciled view of all nodes from all enabled integrations. It is the single most-used screen in the application and the entry point for every node-centric workflow.

### 11.1.1 Aggregation

| ID | Requirement |
|----|-------------|
| `INV-001` | The platform **MUST** aggregate inventory from all enabled, healthy integrations into a single list. |
| `INV-002` | Aggregation **MUST** be per-request. The platform **MUST NOT** maintain a copy of integration inventory membership — i.e., which nodes each integration currently reports — that requires continuous write-side propagation from integrations to stay current. The platform **MUST** query integrations (or their short-term cache) at request time to determine current membership. This requirement does not prohibit persisting node **identity records** (canonical IDs, linking metadata, lifecycle state) as defined in `DM-1102` — the identity table is the linking substrate used during aggregation, not a mirror of integration inventory. |
| `INV-003` | Aggregation **MUST** respect integration health: an unhealthy integration's data is served from cache (with staleness markers) but does not block the aggregated response. |
| `INV-004` | Aggregation **MUST NOT** wait for the slowest source. Fast sources return immediately; slow sources are included on completion or skipped on timeout (see [section 15](15-error-handling.md) for timeout behavior). |
| `INV-005` | The platform **MUST** indicate to the user when an aggregated result is partial — explicitly listing which sources contributed, which were unavailable, and which are stale. |

### 11.1.2 Deduplication and identity linking

| ID | Requirement |
|----|-------------|
| `INV-101` | The platform **MUST** recognize that the same physical or logical node may be reported by multiple integrations and present it as a single inventory entry. |
| `INV-102` | The platform **MUST** support the following identity attributes for linking: certname, FQDN, hostname, primary IP. The set is extensible per plugin. |
| `INV-103` | The platform **MUST** apply configurable linking rules to determine which attributes to compare and in what order of precedence. |
| `INV-104` | Default linking rule: prefer certname (when both candidates carry one); fall back to FQDN; fall back to hostname (case-insensitive); fall back to primary IP only when explicitly enabled (IPs are unstable). |
| `INV-105` | The platform **MUST** surface the linking decision per node — the user **MUST** be able to inspect "this node is the same as that one because their certnames match." |
| `INV-106` | The platform **MUST** support **manual link / unlink overrides** per node. An administrator's manual decision **MUST** take precedence over automatic heuristics. |
| `INV-107` | Manual overrides **MUST** persist across linking-rule changes. Re-running the linker after a rule change **MUST NOT** silently break manual decisions. |
| `INV-108` | Linking rules **MUST** be adjustable without re-processing the entire inventory — changes apply on next aggregation cycle. |
| `INV-109` | The platform **MUST** detect *conflicts* — situations where the linker can identify multiple plausible match targets — and surface them in an "unresolved links" view for administrator action rather than guessing. |
| `INV-110` | The platform **MUST** scale linking to inventories of 10,000+ nodes without quadratic blowup. The linking algorithm **MUST** use indexed attributes; full-cross-product comparison is prohibited. |
| `INV-111` | The platform **MUST** weight identity attributes by per-source confidence (declared by each plugin per [section 4](04-integration-types.md)) — a Puppet certname linked carries more weight than an inferred IP match. |

### 11.1.3 Source attribution

| ID | Requirement |
|----|-------------|
| `INV-201` | Every aggregated node **MUST** display the integrations that know about it ("source attribution"). |
| `INV-202` | Per-source attribution **MUST** be retained at the field level — when two sources disagree on a value, the user **MUST** be able to inspect both. |
| `INV-203` | The platform **MUST** present a default reconciled view (e.g., "OS = Ubuntu 22.04") and, on demand, the per-source breakdown ("PuppetDB: Ubuntu 22.04; Ansible: Ubuntu 22.04.3 LTS"). |

### 11.1.4 Group linking

| ID | Requirement |
|----|-------------|
| `INV-301` | Groups originating from multiple integrations and sharing the same name **MUST** be presented as a single linked group with merged membership. |
| `INV-302` | Group linking **MUST** be configurable: by exact name match (default), by case-insensitive match, by name + qualifier, or disabled. |
| `INV-303` | The platform **MUST** show source attribution per group — "this group is defined in Ansible inventory and AWS tag-derived inventory; merged membership = 23 nodes." |
| `INV-304` | Group hierarchy (nested groups) **MUST** be preserved per source; the platform **MUST NOT** flatten hierarchical groups during merging. |

### 11.1.5 Filtering, search, pagination

| ID | Requirement |
|----|-------------|
| `INV-401` | The platform **MUST** support inventory filtering by: source integration, group, status, fact value, free-text. |
| `INV-402` | Filtering by fact value **MUST** push predicate down to sources where the source supports server-side filtering (e.g., PQL for PuppetDB). |
| `INV-403` | Pagination **MUST** be applied to every list endpoint. Page size **MUST** be configurable, defaulting to a value that preserves first-render performance. |
| `INV-404` | Search **MUST** complete within 2 seconds at the target scale of 10,000 nodes for a healthy primary source. |
| `INV-405` | Cursor-based pagination **MUST** be used for cross-source aggregation rather than offset-based pagination, to maintain consistency under concurrent inventory changes. |

### 11.1.6 Caching and refresh

| ID | Requirement |
|----|-------------|
| `INV-501` | Inventory **MUST** be cached per integration with TTLs declared by each plugin and overridable per integration. |
| `INV-502` | Background refresh **MUST** keep caches warm — users **MUST NOT** routinely encounter cold cache fetches. |
| `INV-503` | The platform **MUST** support incremental refresh where the source supports it: only changed nodes are pulled, not the full inventory. |
| `INV-504` | The platform **MUST** support manual refresh on demand (admin-triggered) per integration. |
| `INV-505` | Cache entries from an unhealthy source **MUST** be retained beyond TTL, served with a staleness marker, until the source recovers. |

## 11.2 Remote execution platform

This section covers the cross-integration aspects of remote execution. Per-integration specifics (Bolt, Ansible, SSH, Bolt; Priority 2 plugins like AWX, Rundeck) are in their own sections.

### 11.2.1 Unified execution interface

| ID | Requirement |
|----|-------------|
| `EXEC-001` | The platform **MUST** present a unified execution interface across all execution-capable integrations. The user chooses an integration, target set, and artifact (command, task, playbook, plan). |
| `EXEC-002` | Target selection **MUST** support: single node, multiple nodes (ad-hoc list), one or more groups, free-text "all nodes matching filter X". |
| `EXEC-003` | Target validation **MUST** confirm that every target is reachable through the chosen execution integration before invoking the underlying tool. Targets the integration cannot reach **MUST** be flagged before submission. |
| `EXEC-004` | The platform **MUST** validate permissions before invoking the underlying tool: RBAC for the action, granular per-command/per-task/per-playbook permission, and command security control (allowlist) where configured. |
| `EXEC-005` | Permission denial **MUST** produce an actionable message identifying which check failed (RBAC vs. allowlist vs. granular). |

### 11.2.2 Streaming output

| ID | Requirement |
|----|-------------|
| `EXEC-101` | Execution stdout and stderr **MUST** stream to the UI in real time. |
| `EXEC-102` | When executing against multiple targets, output **MUST** be attributed per target. |
| `EXEC-103` | Streaming **MUST** survive UI disconnect/reconnect — the server-side execution **MUST NOT** be affected by client disconnection, and on reconnection, the UI **MUST** resume from the last received position with no lost output. |
| `EXEC-104` | Multiple users viewing the same execution **MUST** see the same stream concurrently, with consistent ordering. |
| `EXEC-105` | The platform **MUST** support 100 concurrent streaming executions without dropping output. |
| `EXEC-106` | In-flight execution output **MUST** survive a graceful platform restart without data loss perceived by the user. The platform **MUST** drain in-flight executions on `SIGTERM` — buffered output persisted, streams closed cleanly, or executions handed off if architecture permits — within a configurable drain window before the process exits. For very long executions that exceed the drain window, the platform **MUST** periodically checkpoint buffered output to persistent storage so reconnecting clients after restart can retrieve output produced prior to the restart. A partial-output transcript is **REQUIRED**; silent loss of output is **NOT ACCEPTABLE**. |

### 11.2.3 Execution history

| ID | Requirement |
|----|-------------|
| `EXEC-201` | Every execution **MUST** be recorded with: initiating user, integration, target list, artifact (command/task/playbook/plan + parameters), start time, end time, exit status per target, full transcript per target. |
| `EXEC-202` | Execution history **MUST** be retrievable per node, per user, per integration, and globally, with time-range and status filters. |
| `EXEC-203` | The full transcript of every execution **MUST** be retrievable indefinitely (subject to a configurable retention policy, default unbounded). |
| `EXEC-204` | The platform **MUST** support **re-execution** of a previous execution with one click, with the ability to edit parameters or target set before re-submission. |

### 11.2.4 Concurrency and security controls

| ID | Requirement |
|----|-------------|
| `EXEC-301` | The platform **MUST** enforce concurrent execution limits at three scopes: global (across all integrations), per-integration, per-user. All three are configurable. |
| `EXEC-302` | The platform **MUST** support a **command allowlist** per execution integration — a configured set of commands or patterns the integration is permitted to run. Commands not on the allowlist **MUST** be rejected before invocation. Allowlist entries use **glob syntax**: `*` matches any sequence of characters within a single argument token; `**` matches across argument boundaries. Regex is explicitly not supported in allowlist entries. Examples: `systemctl restart *` permits restarting any service; `systemctl * nginx` permits any systemctl operation on nginx. An empty allowlist means all commands are permitted (open); a non-empty allowlist means only matching commands are permitted (closed). |
| `EXEC-303` | The allowlist **MUST** be configurable per role: a role may have access to a different allowlist than another role on the same integration. A user with multiple roles receives the union of all matching allowlists across their roles. |
| `EXEC-304` | The platform **MUST** support per-task allowlists for Bolt and per-playbook allowlists for Ansible — a role may run only a subset of available tasks/playbooks. |
| `EXEC-305` | The platform **MUST** support **block patterns** — explicit denials that take precedence over allowlists, using the same glob syntax as allowlist entries (`EXEC-302`). A command matching both an allowlist entry and a block pattern **MUST** be denied. Block patterns are evaluated after allowlist matching; a match terminates the evaluation chain with rejection. |
| `EXEC-306` | The platform **MUST** apply timeouts per execution: wall-clock and idle, configurable per integration and overridable per execution. The platform **MUST** terminate runaway executions. |

## 11.3 Node journal and event timeline

The journal is the per-node history of significant events. The global timeline is its cross-node companion.

> **Architectural principle: source tools remain the source of truth.** The journal does NOT duplicate data from external tools into a local database. Events from PuppetDB, monitoring tools, cloud APIs, etc. are fetched on-demand from the source when the user views the journal. Only data that Vigil originates (executions, manual notes) is persisted locally. This avoids data duplication, keeps the source tool authoritative, and eliminates the need for ingestion pipelines, pollers, and retention management for external data.

### 11.3.1 Per-node journal

| ID | Requirement |
|----|-------------|
| `JRN-001` | The platform **MUST** present a per-node journal aggregating events from all enabled, journal-contributing integrations. Events from external sources are fetched on-demand; only Vigil-originated entries (executions, manual notes) are persisted locally. |
| `JRN-002` | Journal entries **MUST** carry: timestamp, source integration, event type, summary, optional structured details, and (where applicable) a back-reference to the originating artifact (report, execution transcript, provisioning task). |
| `JRN-003` | Journal entries **MUST** be filterable by: type, source, time range, severity. Time range and source filters are passed to upstream APIs to scope the query. |
| `JRN-004` | Journal entries **MUST** be sortable by time (default: newest first). |
| `JRN-005` | The journal **MUST** preserve grouping where the source defines it (e.g., events from a single Puppet report grouped under that report). |
| `JRN-006` | The journal **MUST** support pagination via "load more" (cursor-based per source). |

### 11.3.2 Global timeline

| ID | Requirement |
|----|-------------|
| `JRN-101` | The platform **MUST** provide a global timeline view of journal entries across all nodes. |
| `JRN-102` | The global timeline **MUST** be filterable by: node, group, type, source, time range, severity. |
| `JRN-103` | Full-text search is limited to entries currently loaded in the browser. The platform **MUST** support client-side text filtering of rendered entries. Cross-source server-side full-text search is explicitly out of scope — operators use source-native tools for deep historical text search. |

### 11.3.3 Data sourcing model

| ID | Requirement |
|----|-------------|
| `JRN-201` | The platform **MUST** apply the journal contribution rules in [section 4.10](04-integration-types.md#410-journal-behavior-summary) without exception. |
| `JRN-202` | External events (from integrations) are fetched on-demand from the source tool's API when the user views the journal. The platform **MUST NOT** store copies of external events in a local database. The source tool is the single source of truth. **Consequence:** external journal history for a decommissioned (or unreported) node is only available for as long as the upstream tool retains it. Vigil does not archive external events on decommission. Operators requiring long-term external event history MUST configure retention at the source (e.g., PuppetDB `node-purge-ttl`, CloudTrail retention policies). The UI MUST surface this limitation with a notice when displaying the journal of a decommissioned node. |
| `JRN-203` | Vigil-originated data (execution results, manual notes) **MUST** be persisted locally in PostgreSQL, as Vigil is the authoritative source for this data. |
| `JRN-204` | The platform **MUST** preserve the originating source's event ID where one exists, for back-reference and deduplication within a single fetch. |
| `JRN-205` | The journal view **MUST NOT** auto-refresh by default. Fresh data is fetched only on explicit user action (page load, navigation, or manual refresh button). |
| `JRN-206` | The platform **MUST** offer an opt-in auto-refresh toggle with selectable interval (default off). When enabled, the UI **MUST** display a notice that periodic upstream API calls are being made. |
| `JRN-207` | The platform **MUST** render the journal progressively — locally-stored entries appear immediately; external source results appear as each API responds. The UI **MUST** indicate which sources are still loading and which have failed. |

### 11.3.4 Manual notes

| ID | Requirement |
|----|-------------|
| `JRN-301` | Users **MUST** be able to add manual journal entries (notes) on a per-node or per-group basis. |
| `JRN-302` | Manual entries **MUST** carry the authoring user's identity and a creation timestamp. |
| `JRN-303` | Manual entries **MAY** be edited or deleted by the authoring user; an audit trail of edits **MUST** be preserved. |
| `JRN-304` | Manual entries **MUST NOT** be confused with system entries — visually distinct in the UI; tagged with `source: manual`. |
| `JRN-305` | Manual entries **MUST** support free-text content with optional structured tags (e.g., `incident-2026-04-15`, `change-request-7842`). |

### 11.3.5 Linking back to source

| ID | Requirement |
|----|-------------|
| `JRN-401` | Where a journal entry derives from a structured artifact (Puppet report, execution transcript, provisioning task), the entry **MUST** link back to that artifact. |
| `JRN-402` | Following the link **MUST** open the relevant detail view (report drill-down, execution transcript, provisioning task) in the same UI session. |
| `JRN-403` | Where a journal entry derives from a remote system whose record is itself navigable (e.g., AWS CloudTrail event), the platform **MAY** offer a deep link out, with explicit indication that it leads outside Vigil. |

## 11.4 Authentication

### 11.4.1 Local authentication and sessions (CE)

| ID | Requirement |
|----|-------------|
| `AUTH-001` | The platform **MUST** support local user authentication with username and password. |
| `AUTH-002` | Local user passwords **MUST** be stored using a current, vetted password-hashing algorithm with appropriate work factor. |
| `AUTH-003` | The platform **MUST** support local user management actions: create, disable, enable, delete, reset password. |
| `AUTH-004` | The platform **MUST** support session-based authentication with configurable session lifetime and idle timeout. |
| `AUTH-005` | The platform **MUST** support API token authentication for programmatic access (CLI, MCP, automation). Tokens are scoped to a user and inherit the user's roles. |
| `AUTH-006` | Token issuance, listing, and revocation **MUST** be available to the user (their own tokens) and to administrators (any user's tokens). |
| `AUTH-007` | The platform **MUST** enforce a minimum password complexity, rate-limit login attempts, and log authentication failures with sufficient detail for security review. |
| `AUTH-008` | The platform **MUST** support password change for the authenticated user. |
| `AUTH-009` | Local authentication **MUST** remain functional even when external authentication is unavailable (break-glass access). The platform **MUST** ensure at least one local administrator account always exists and cannot be deleted or externally-IdP-bound. This account is the canonical break-glass path. Break-glass logins **MUST** be surfaced in the audit trail with a distinct marker. The platform **MUST** alert administrators (via the UI and structured log) whenever the break-glass account is used to authenticate. |
| `AUTH-010` | The platform **MUST** debounce writes of the session's "last active" timestamp to at most once per configurable interval (default 5 minutes). Unbounded write-per-request **MUST NOT** occur. The debounce interval **MUST** remain short enough that idle-timeout enforcement is accurate within one interval. |

### 11.4.2 OIDC authentication (CE)

A minimal OIDC profile ships in CE so self-hosted teams can integrate with their identity provider (Google Workspace, GitHub, Keycloak, Azure AD via OIDC) without an enterprise license. The profile is deliberately scoped to what a small team needs.

| ID | Requirement |
|----|-------------|
| `AUTH-051` | The platform **MUST** support OIDC / OAuth 2.0 authentication with a single configured OIDC provider. |
| `AUTH-052` | Users authenticating via OIDC **MUST** be JIT-provisioned — a user record is created on first successful authentication via the OIDC provider. No pre-provisioning is required. |
| `AUTH-053` | The platform **MUST** support **direct (literal) group-to-role mapping** for the OIDC provider: administrator configures exact-match group names that map to roles. Wildcard patterns and regular expressions are **NOT** included in CE (see `AUTH-108` for EE). |
| `AUTH-054` | OIDC users **MUST** authenticate exclusively through their IdP — the platform **MUST NOT** store or accept passwords for OIDC-authenticated users. |
| `AUTH-055` | Local users and OIDC users **MUST** coexist. Local accounts remain available for initial setup, break-glass, and environments without an IdP. |
| `AUTH-056` | When the OIDC provider is unavailable, already-authenticated sessions **MUST** continue to serve; new OIDC logins **MUST** fail with a clear error; local authentication remains available. |
| `AUTH-057` | The platform **MUST NOT** support multiple concurrent OIDC providers in CE. Multi-IdP OIDC is an EE capability (see `AUTH-102`). |

### 11.4.3 Enterprise external authentication (EE)

> **Edition:** The requirements in this section are provided by `vigil_enterprise` and require a valid EE license (see `docs/specs/editions.md`). They extend — but do not replace — the CE OIDC baseline in 11.4.2. A CE-only deployment implements `AUTH-001` through `AUTH-057` and nothing in this section.

| ID | Requirement |
|----|-------------|
| `AUTH-101` | The platform (EE) **MUST** support **SAML 2.0** authentication for enterprise SSO (Okta, Azure AD, ADFS, Keycloak). |
| `AUTH-102` | The platform (EE) **MUST** support **multiple concurrent OIDC providers** — extending the CE single-provider baseline — so staff and contractors (or multiple business units) can authenticate via different OIDC IdPs simultaneously. |
| `AUTH-103` | The platform (EE) **MUST** support **LDAP / Active Directory** authentication via direct bind or search-based bind. |
| `AUTH-104` | EE external users **MUST** authenticate exclusively through their IdP, with the same password-absence constraint as CE OIDC users (`AUTH-054`). |
| `AUTH-105` | EE **MUST** extend JIT provisioning to all EE-supported IdP types (SAML, LDAP, multi-IdP OIDC) with the same zero-pre-provisioning contract as `AUTH-052`. |
| `AUTH-106` | EE **MUST** allow administrators to disable local authentication entirely (with explicit confirmation that a break-glass plan exists outside Vigil). When local auth is disabled, the CE break-glass account (`AUTH-009`) is also disabled — the operator is solely responsible for maintaining an out-of-band access path (e.g., host-level CLI access, IdP emergency account). Disabling local authentication is **NOT** available in CE — CE always keeps the break-glass local admin account as a permanent fallback path. |
| `AUTH-107` | EE **MUST** support multiple IdPs of different protocols concurrently — e.g., SAML for staff plus OIDC for contractors plus LDAP for service accounts. |
| `AUTH-108` | EE **MUST** extend group-to-role mapping beyond the CE literal-match baseline (`AUTH-053`) with **wildcard patterns** — e.g., groups matching `vigil-*` map to a Vigil role named after the suffix. |
| `AUTH-109` | EE **MUST** re-evaluate group memberships on each authentication event (or token refresh, where applicable) — group changes propagate without requiring user re-creation. Multi-group resolution **MUST** be additive: a user in groups A, B, C receives roles from all matching mappings. CE's literal OIDC mapping is a simpler subset of this behaviour. |
| `AUTH-110` | When an EE-configured IdP is unavailable, the platform **MUST** continue serving authenticated sessions for users whose tokens are still valid; new logins via that IdP **MUST** fail with a clear error; break-glass access remains available subject to `AUTH-106`. |

## 11.5 Authorization and RBAC

### 11.5.1 Role model

| ID | Requirement |
|----|-------------|
| `RBAC-001` | The platform **MUST** support role-based access control. Permissions are assigned to roles; roles are assigned to users (directly for local, via group mapping for external). |
| `RBAC-002` | A user **MAY** have multiple roles. Effective permissions are the union of all assigned roles. |
| `RBAC-003` | Role definitions **MUST** be administrator-managed via the platform's UI and API. |
| `RBAC-004` | The platform **MUST** ship with a sane set of default roles: `administrator`, `operator`, `read-only`, `auditor`. Default roles' permission sets **MUST** be modifiable. |
| `RBAC-005` | Permissions **MUST** be enforced consistently across web UI, API, MCP server, and (future) CLI — no surface bypasses RBAC. |

### 11.5.2 Permission granularity

| ID | Requirement |
|----|-------------|
| `RBAC-101` | Permissions **MUST** be granular at three scopes: **integration type** (e.g., "view facts"), **specific integration** (e.g., "view facts only from this Ansible integration, not that one"), **specific action** (e.g., "execute Bolt commands but only the `service` task"). |
| `RBAC-102` | The platform **MUST** support **per-command and per-node/group restrictions** for Remote Execution: a role may execute a defined set of shell commands or matching patterns, and those restrictions **MAY** be further scoped to specific nodes or groups. Permission evaluation is **per-target**: when a multi-target execution includes both permitted and denied targets, the platform **MUST** proceed against the permitted targets and surface the denied targets explicitly — identifying each denied target, the failing check (RBAC scope, allowlist, or command pattern), and the user's effective permission — rather than rejecting the entire execution. Executions where *all* targets are denied **MUST** be rejected before invocation. |
| `RBAC-103` | The platform **MUST** support **per-task restrictions** for Bolt and Ansible — a role may run only specific tasks or modules. |
| `RBAC-104` | The platform **MUST** support **per-playbook restrictions** — a role may run only specific playbooks. |
| `RBAC-105` | The platform **MUST** support **per-provisioning-action and per-node/group restrictions** — a role may perform only specific lifecycle operations on specific integrations, and those restrictions **MAY** be further scoped to specific nodes or groups. |
| `RBAC-106` | Granular permissions **MUST** apply regardless of authentication method. |
| `RBAC-107` | The platform **MUST** support per-target scoping across **all surfaces** — inventory reads, facts, configuration, journal, execution, and provisioning. A role's target scope restricts which nodes a user can see in the inventory, not only which nodes they can act on. Per-node/group scoping **MUST** apply to all capability types (view, execute, provision, etc.). Target scope filtering is applied at presentation time against the full shared integration cache — not at cache-fetch time — so cache entries remain unscoped and shared across users (see `CACHE-006`). |
| `RBAC-108` | Target-scope evaluation across N targets in a single authorization check **MUST** issue a constant (bounded) number of data-store queries regardless of N. Linear (per-target) query patterns **MUST NOT** be used in the evaluator's hot path. This requirement applies at submission time (pre-execution) and at run time (for scheduled executions, per `FUT-106`). |
| `RBAC-109` | When an execution proceeds with a mix of permitted and denied targets (per `RBAC-102`), the audit trail **MUST** record the full intended target list, the per-target permission decision (permitted / denied with reason), and the set of targets actually dispatched. Denied targets **MUST NOT** produce Execution records (see `DM-601`) — the audit trail is the sole authoritative record of denied nodes. A partial execution is not silent: the submitting user sees denied targets surfaced at dispatch time; the audit trail preserves the full intent for administrators. |

### 11.5.3 Group-to-role mapping

CE provides literal group-to-role mapping for the OIDC provider. EE extends this with wildcard patterns, IdP group re-evaluation on every login, and additive multi-group resolution across multiple IdPs.

| ID | Requirement |
|----|-------------|
| `RBAC-201` | The platform **MUST** support administrator-configured mappings from external IdP groups to Vigil roles. |
| `RBAC-202` | Mappings **MUST** support multiple group memberships — a user in groups A, B, C maps to all roles those groups confer (additive). |
| `RBAC-203` | The platform **MUST** support a configurable **default role** for users whose external groups do not match any mapping. The default **MAY** be set to "deny access" to enforce explicit allow-listing. |
| `RBAC-204` | Mappings **MUST** support wildcard patterns — e.g., groups matching `vigil-*` map to a Vigil role named after the suffix. **Wildcard patterns are an EE feature**; CE supports literal-match group names only (see `AUTH-053`, `AUTH-108`). |
| `RBAC-205` | The platform **MUST** re-evaluate group memberships on each authentication event (or token refresh, where applicable) — group changes propagate without requiring user re-creation. **Re-evaluation on every login is an EE feature**; CE applies group mapping at JIT provisioning and at explicit administrator "refresh user" actions (see `AUTH-109`). |
| `RBAC-206` | The platform **MUST** display, per user, the source of each role assignment (direct vs. group-mapped) and the originating group for transparency. |

### 11.5.4 Audit trail

| ID | Requirement |
|----|-------------|
| `RBAC-301` | The platform **MUST** maintain an audit trail of user-initiated actions: authentication events, RBAC changes, configuration changes, executions, provisioning actions, manual journal edits. |
| `RBAC-302` | Each audit entry **MUST** include: timestamp, actor, action, target, parameters (with secrets redacted), result. |
| `RBAC-303` | The audit trail **MUST** be retrievable by administrators and auditors with filtering by actor, action type, target, and time range. |
| `RBAC-304` | The audit trail **MUST NOT** be modifiable by ordinary users. Administrators **MAY** export but **MUST NOT** delete entries (subject to a configurable retention policy). |
| `RBAC-305` | For irreversible actions (remote execution submission, provisioning lifecycle operations, environment deployment, RBAC and integration configuration changes), the audit entry **MUST** be recorded in state `pending` **before** the action's side effect is initiated, and transitioned to `success` or `failure` on completion. A crash or partition between the pending write and the action finalisation **MUST** leave a durable `pending` record that can be reconciled — it **MUST NOT** leave a side effect with no audit record. |
| `RBAC-306` | Read-only actions (inventory queries, fact lookups, journal viewing) **MAY** use a simpler write-after-action audit pattern, or be sampled at configurable rates, since their absence from the audit trail does not create an accountability gap. |

## 11.6 Resilience

### 11.6.1 API-based integrations

| ID | Requirement |
|----|-------------|
| `RES-001` | API-based integrations (PuppetDB, Puppetserver, cloud APIs, monitoring APIs, etc.) **MUST** implement a circuit breaker per integration. |
| `RES-002` | The circuit breaker **MUST** open after `N` consecutive failures (default `N` = 5, configurable per integration) and remain open for a cooldown period (default 30 seconds). |
| `RES-003` | While open, the breaker **MUST** short-circuit calls — failing fast with a structured error rather than blocking on the upstream. |
| `RES-004` | After the cooldown, the breaker **MUST** allow a probe call. On success, the breaker closes; on failure, it remains open and the cooldown extends (configurable backoff). |
| `RES-005` | API-based integrations **MUST** implement retry with exponential backoff for transient failures (timeouts, 5xx, rate-limit). The number of retries and the backoff curve **MUST** be configurable per integration. |
| `RES-006` | Retries **MUST NOT** cascade through the circuit breaker — a closed-then-tripped breaker stops retry attempts, not the other way round. |

### 11.6.2 CLI-based integrations

| ID | Requirement |
|----|-------------|
| `RES-101` | CLI-based integrations (Bolt, Ansible, SSH) **MUST** apply both **wall-clock timeout** and **idle timeout** to every CLI invocation. |
| `RES-102` | Wall-clock timeout default: 1 hour. Idle timeout default: 5 minutes. Both **MUST** be overridable per integration and per command. |
| `RES-103` | When either timeout fires, the platform **MUST** terminate the CLI process and record the timeout in the execution transcript. |
| `RES-104` | The platform **MUST** detect "ghost" CLI processes (parent killed, child orphaned) and reap them. |

### 11.6.3 Cross-cutting

| ID | Requirement |
|----|-------------|
| `RES-201` | Every external call (API or CLI) **MUST** have an explicit timeout. There is no "wait forever" mode. |
| `RES-202` | An unhealthy integration **MUST NOT** cascade health failure to other integrations. Plugin isolation is enforced. |
| `RES-203` | The platform **MUST** detect **degraded state** — partial functionality, where some capabilities of an integration work and others fail. The integration's per-capability health **MUST** drive UI behavior (e.g., gray out a failing tab while leaving others functional). |
| `RES-204` | Recovery detection **MUST** be automatic. The platform **MUST** periodically probe broken integrations and resume normal operation when they recover. |
| `RES-205` | The platform **MUST** rate-limit retries to avoid amplifying upstream incidents. |

## 11.7 Health and observability

### 11.7.1 Per-integration health

| ID | Requirement |
|----|-------------|
| `HEALTH-001` | The platform **MUST** maintain per-integration health status, refreshed periodically (default: every 30 seconds, configurable). |
| `HEALTH-002` | Health status **MUST** include: overall integration health, per-capability health, last successful call timestamp, last failure timestamp, last failure detail. |
| `HEALTH-003` | Health checks **MUST** use lightweight probes — they **MUST NOT** dominate the integration's call budget. |
| `HEALTH-004` | Health check failures **MUST NOT** cascade. One unhealthy integration's failing probe **MUST NOT** fail another's. |
| `HEALTH-005` | Continuous per-integration health probing **MUST** be owned by a single canonical mechanism per integration (see design for the concrete process model). Scheduled background-job queues **MUST NOT** duplicate the liveness-probe role — they **MAY** only schedule lower-frequency maintenance tasks (retention sweeps, long-horizon recomputations). Double-firing of health probes **MUST NOT** occur. |

### 11.7.2 Integration status dashboard

| ID | Requirement |
|----|-------------|
| `HEALTH-101` | The platform **MUST** provide an integration status dashboard accessible to administrators. |
| `HEALTH-102` | The dashboard **MUST** display: each enabled integration, its overall health, per-capability health, last-successful-call timestamps, and an actionable diagnostic message for each failing capability. |
| `HEALTH-103` | The dashboard **MUST** allow administrators to manually trigger a health check, refresh credentials, restart the integration's connection pool, and disable/re-enable the integration. |
| `HEALTH-104` | The platform **MUST** track per-integration health state transitions over a rolling window (default: last 30 minutes, configurable). An integration is considered **flapping** when it has recorded three or more healthy↔unhealthy transitions within that window. The platform **MUST** surface flapping as a distinct status, separate from healthy, degraded, and unhealthy. |
| `HEALTH-105` | The integration administration UI **MUST** present each integration as a card with: (a) aggregate status indicator (healthy / degraded / unhealthy / flapping) as the headline; (b) an expandable detail panel showing per-capability status, last-success timestamp, last-failure timestamp, and last diagnostic message for each capability; (c) a flap indicator showing the number of state changes in the current rolling window when flapping is active. |

### 11.7.3 Platform observability

| ID | Requirement |
|----|-------------|
| `HEALTH-201` | The platform **MUST** expose its own internal metrics suitable for external monitoring: request rates, error rates, latency percentiles, cache hit rates, integration call counts, plugin resource usage. |
| `HEALTH-202` | The platform **MUST** produce structured logs at multiple severity levels with consistent field naming across components. |
| `HEALTH-203` | Logs **MUST NOT** contain credentials, tokens, or other secrets. Plugins **MUST** redact sensitive parameters before logging. |
| `HEALTH-204` | The platform **MUST** offer a health check endpoint suitable for load balancers and uptime monitoring (returns overall application health). |

## 11.8 Performance and scale

| ID | Requirement |
|----|-------------|
| `PERF-001` | The platform **MUST** support inventories of 10,000 nodes without functional degradation. |
| `PERF-002` | First-page render of any list view at the target scale, given a healthy primary source, **MUST** complete within 2 seconds. |
| `PERF-003` | Background refresh **MUST** keep caches warm so users **MUST NOT** experience "cold cache" latency in normal operation. |
| `PERF-004` | The platform **MUST** apply **request deduplication / coalescing** — multiple concurrent requests for the same data **MUST** result in one upstream call. |
| `PERF-005` | Pagination **MUST** be applied to every list endpoint with cursor-based pagination preferred for cross-source aggregation. |
| `PERF-006` | The platform **MUST** apply per-source timeouts for aggregation operations — fast sources return immediately rather than blocking on slow ones. |
| `PERF-007` | The platform **MUST** support 5 concurrent active users without queuing read requests. |
| `PERF-008` | The platform **MUST** support 100 concurrent streaming executions without dropping output. |
| `PERF-009` | The platform **MUST** apply **incremental updates** where upstream APIs support them — pull only what changed since the last refresh. |
| `PERF-010` | In multi-node deployments, cache locality across nodes **MUST** be documented. Stateless API and MCP surfaces that route to any node **MUST** either: (a) use a client-affinity mechanism at the load balancer (e.g., keyed on API-token principal) so repeated requests from the same principal warm the same node's cache, or (b) accept reduced cache-hit rates proportional to the node count and document this explicitly. Live-updating LiveView connections **MUST** use WebSocket stickiness in all multi-node deployments. |

## 11.9 Caching strategy

| ID | Requirement |
|----|-------------|
| `CACHE-001` | The platform **MUST** support per-integration, per-capability cache TTLs, declared by the plugin and overridable by administrator. |
| `CACHE-002` | TTL defaults **MUST** be sensible per data type: inventory minutes; facts minutes-to-hours; configuration minutes; reports for completed runs hours; monitoring seconds. Per-plugin defaults are normative. |
| `CACHE-003` | The cache **MUST** support manual invalidation (cache flush) per integration, per capability, and per node. Every plugin **MUST** expose this cache flush action to users (see `PLUG-013` in [section 6](06-plugin-architecture.md)), enabling operators to request fresh data on demand. This mechanism justifies higher default TTLs where data changes infrequently. |
| `CACHE-004` | The cache **MUST** support webhook-driven invalidation where integrations publish change notifications (e.g., Puppet code-deploy events). |
| `CACHE-005` | When the upstream is unhealthy, cache entries **MUST** be retained beyond TTL with explicit staleness markers shown to the user. |
| `CACHE-006` | The cache stores **full, unfiltered integration responses** keyed by integration and capability. RBAC filtering is applied in the application layer at presentation time — after the cache lookup and before the response is returned to the user. Cache entries are **shared across all users** who have access to a given integration; per-principal cache entries are not used. This model is efficient: filtering 10,000 nodes against a user's permission scope in memory is orders of magnitude cheaper than maintaining separate per-principal cache entries. The consequence is that the cache must hold the full integration inventory, not paginated slices (pagination is applied after RBAC filtering). |
| `CACHE-007` | The platform **MUST NOT** cache write-side responses (executions, provisioning actions) beyond the duration of the in-flight request. |
| `CACHE-008` | The cache **MUST** have a configurable size budget per integration and **MUST** apply a documented eviction policy when the budget is exceeded. |
| `CACHE-009` | The platform **MUST** warm high-priority caches in the background after startup so users **MUST NOT** routinely experience empty-cache latency in the minutes following a deploy. Warming **MUST** be prioritised by data type (inventory first, facts next) and **MUST NOT** monopolise per-integration concurrency budgets used by user-initiated requests. The set of capabilities warmed at startup, and their priorities, **MUST** be configurable per integration. |
| `CACHE-010` | The platform **MUST NOT** depend on snapshotting cache state to persistent storage to survive restarts. Cold-start warming from the source tool is the canonical recovery path; persistent cache snapshots, if implemented, are an optimisation only. |

## 11.10 Configuration

| ID | Requirement |
|----|-------------|
| `CFG-001` | The platform **MUST** load configuration from a single, authoritative source. Per-environment overrides **MAY** be layered. |
| `CFG-002` | Configuration **MUST** be validated at startup. Validation errors **MUST** prevent startup with clear, actionable messages identifying the offending field, the violated rule, and a remediation hint. |
| `CFG-003` | The platform **MUST** support per-integration enable/disable without modifying any other configuration. |
| `CFG-004` | Sensitive values (credentials, certificates, tokens) **MUST** be handled through a secrets-aware mechanism: reference-based, never in plain text in default storage; redacted from logs and UI displays. |
| `CFG-005` | The platform **MUST** support reload of configuration without full application restart, where the change permits it. |
| `CFG-006` | The platform **MUST** provide a guided configuration UI for plugins, with field-level validation and a "test connection" action exercising the integration without performing side effects. |
| `CFG-007` | The platform **MUST** version configuration changes (with audit trail) so an administrator can review what changed, when, and by whom. |

---

[← Previous: P2/P3 Integrations](10-priority-2-3-integrations.md) | [Next: Data Model →](12-data-model.md)

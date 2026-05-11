# 20. Implementation Roadmap

The system is implemented as ordered **feature sets**. Each set is self-contained, has clear scope, has acceptance criteria, and **MUST** include the required tests defined in [section 16](16-testing-philosophy.md). Feature sets are tackled in the order listed — each builds on the previous.

The roadmap is sequence-prescriptive but not date-prescriptive. The order matters; the calendar is the team's to set.

## 20.1 Roadmap principles

| ID | Requirement |
|----|-------------|
| `ROAD-001` | The system **MUST** be built feature set by feature set in the order defined below. Skipping a feature set **MUST NOT** be done — each is a prerequisite for those that follow. |
| `ROAD-002` | Each feature set **MUST** be released into a working state before the next is started. "Almost working" is not allowed to accumulate. |
| `ROAD-003` | A feature set is complete when its acceptance criteria pass and the tests required by [section 16](16-testing-philosophy.md) are green. |
| `ROAD-004` | Bugs discovered in a completed feature set **MUST** be fixed before progress continues, except where deferral is explicitly recorded as a known limitation. |
| `ROAD-005` | The plugin contract is established by Feature Set 1 and **MUST NOT** be substantively changed once Feature Set 4 has shipped — every subsequent integration depends on its stability. Breaking changes after that point require a contract major-version bump. |

## 20.2 Feature Set 1 — Core Platform + Plugin SDK

**Scope:** Application skeleton, plugin contract definition, configuration system, health check framework, basic HTTP server with no integrations yet.

**Acceptance criteria:**

- [ ] The plugin contract is fully defined and documented (per [section 6](06-plugin-architecture.md)).
- [ ] A plugin can be registered, initialized, health-checked, and shut down through the lifecycle hooks.
- [ ] Configuration is loaded, validated against schema, and accessible to plugins.
- [ ] A health check endpoint returns the status of all registered plugins.
- [ ] A reference "no-op" test plugin can be loaded to verify the contract end-to-end.
- [ ] The platform contract conformance test suite is published and passes against the no-op plugin.
- [ ] The application starts cleanly with no integrations enabled.

**Required tests:** Plugin lifecycle integration tests; configuration validation property tests; reference plugin smoke test.

## 20.3 Feature Set 2 — SSH Integration

**Scope:** First real integration. Proves the plugin contract works end-to-end against a real external system.

**Acceptance criteria:**

- [ ] SSH config file is parsed into inventory.
- [ ] Nodes appear in the inventory API.
- [ ] Facts can be gathered via SSH commands per [section 8.4.2](08-priority-1-integrations.md#842-facts).
- [ ] Commands can be executed with streaming output meeting the latency target (< 200 ms).
- [ ] Execution history is stored and retrievable.
- [ ] Health check reports SSH connectivity status with per-host probing.
- [ ] Connection pooling works.
- [ ] Wall-clock and idle timeouts terminate runaway processes.

**Required tests:** Inventory parse correctness; streaming reconnection; timeout enforcement; permission denial paths.

## 20.4 Feature Set 3 — Authentication + RBAC

**Scope:** Local user management, session-based auth, role-based permissions. External authentication is deferred to Feature Set 12.

**Acceptance criteria:**

- [ ] Users can register, log in, log out.
- [ ] Roles with permissions can be created and assigned.
- [ ] API endpoints enforce permissions; unauthorized requests return the correct error without leaking detail.
- [ ] Audit trail records user actions per [section 11.5.4](11-platform-requirements.md#1154-audit-trail).
- [ ] API token authentication works alongside session-based.
- [ ] Token issuance, listing, and revocation work.
- [ ] Default roles ship and behave correctly.
- [ ] Granular per-command permissions on SSH execution work.

**Required tests:** RBAC permission evaluation property tests; auth brute-force resistance; audit trail correctness.

## 20.5 Feature Set 4 — Puppet Integration (Inventory + Facts)

**Scope:** PuppetDB connection, node inventory, facts retrieval. Read-only.

**Acceptance criteria:**

- [ ] PuppetDB nodes appear in unified inventory alongside SSH nodes.
- [ ] Node identity linking works between Puppet certnames and SSH hostnames.
- [ ] Facts are retrievable per node from PuppetDB.
- [ ] Inventory queries use PQL for server-side filtering.
- [ ] Circuit breaker trips on PuppetDB failures and recovers automatically.
- [ ] mTLS authentication works with client certificates.
- [ ] Inventory at 10,000 PuppetDB nodes performs within latency targets.
- [ ] Source attribution is preserved through aggregation.

**Required tests:** Linking property tests; PuppetDB failure / recovery; performance test at 10,000-node scale.

## 20.6 Feature Set 5 — Bolt Integration (Inventory + Execution)

**Scope:** Bolt inventory parsing, command and task execution.

**Acceptance criteria:**

- [ ] Bolt inventory.yaml is parsed into nodes and groups, including nested groups.
- [ ] Commands can be executed via Bolt CLI with per-target streaming output.
- [ ] Tasks are discoverable with parameter metadata; auto-generated parameter forms work.
- [ ] Plans can be executed with parameter input.
- [ ] Execution timeouts (wall-clock and idle) work correctly.
- [ ] Per-task and per-plan RBAC granular permissions enforce.
- [ ] Concurrent execution limits enforce.

**Required tests:** Inventory parse coverage including nested groups; per-target attribution; permission denial paths.

## 20.7 Feature Set 6 — Puppet Integration (Events + Reports + Configuration)

**Scope:** Full Puppet depth — reports, events, catalogs, Hiera, code deployment.

**Acceptance criteria:**

- [ ] Puppet reports are retrievable with all required metrics (per [section 7.9](07-puppet-integration.md#79-reports)).
- [ ] Change events are extracted from reports correctly; no-op runs produce no events.
- [ ] Resource events feed the journal grouped under their report.
- [ ] Catalogs are retrievable with resource relationships.
- [ ] Catalog diff between environments works.
- [ ] Hiera data is browsable with hierarchy level attribution.
- [ ] Per-key Hiera resolution (lookup chain, merge strategies, class-aware) works.
- [ ] Hiera key usage analysis returns consuming classes with file/line references.
- [ ] Environment list, cache flush, and code deployment (webhook + remote-exec) work.

**Required tests:** Event extraction property tests including no-op handling; Hiera resolution correctness across hierarchy variations; catalog diff correctness.

## 20.8 Feature Set 7 — Ansible Integration

**Scope:** Ansible inventory, facts, command/playbook execution. Validates plugin contract generality.

**Acceptance criteria:**

- [ ] Ansible inventory (static + dynamic) is parsed into nodes and groups.
- [ ] Facts are gatherable via setup module and cached appropriately.
- [ ] Ad-hoc commands execute with streaming output.
- [ ] Playbooks execute with extra vars support.
- [ ] Plugin contract identical to SSH/Bolt (no plugin-specific platform code).
- [ ] Per-playbook RBAC granular permissions enforce.

**Required tests:** Plugin contract conformance; inventory parse coverage including dynamic; permission denial paths.

## 20.9 Feature Set 8 — Node Journal

**Scope:** Journal storage, event extraction from reports, manual notes, global timeline.

**Acceptance criteria:**

- [ ] Journal entries are created from executions, provisioning actions (when available), and Puppet events.
- [ ] Per-node timeline is filterable by type, source, date range, severity.
- [ ] Global timeline works with cross-node filtering and free-text search.
- [ ] Manual notes can be added by users with the appropriate permission.
- [ ] Manual note edits preserve history.
- [ ] Journal entries link back to their source artifact (report, execution).
- [ ] Live updates appear without manual refresh.
- [ ] Journal retention works per the configured policy.

**Required tests:** Event extraction grouping correctness; live update arrival ordering; manual note auditing.

## 20.10 Feature Set 9 — Unified Inventory (Linking + Deduplication)

**Scope:** Cross-integration node identity resolution, manual linking, group linking, full unification across all configured integrations.

**Acceptance criteria:**

- [ ] Automatic linking correctly merges nodes across sources by configurable rules.
- [ ] Manual link/unlink overrides work per-node and persist across rule changes.
- [ ] Linked nodes show source attribution from all contributing integrations.
- [ ] Groups with the same name across sources are linked.
- [ ] Deduplication handles 5,000+ nodes without performance degradation.
- [ ] Conflict cases (multiple plausible matches) surface in an "unresolved links" view.
- [ ] Per-source identity confidence weights influence linking decisions correctly.

**Required tests:** Linking property tests at scale; manual override persistence; group merging correctness.

## 20.11 Feature Set 10 — Provisioning (Proxmox)

**Scope:** First provisioning integration.

**Acceptance criteria:**

- [ ] Proxmox VMs and containers appear in inventory.
- [ ] VMs and containers can be created, destroyed, started, stopped, rebooted.
- [ ] Resource discovery (cluster nodes, templates, storage, networks) works.
- [ ] Provisioning actions generate journal entries from the Proxmox task log via realtime API queries.
- [ ] Newly provisioned nodes appear in unified inventory within one refresh cycle.
- [ ] Long-running operations report state transitions in real time.
- [ ] Per-action RBAC granular permissions enforce.

**Required tests:** End-to-end create/destroy flow; journal sourced from Proxmox task log; state transition reporting.

## 20.12 Feature Set 11 — Provisioning (AWS + Azure)

**Scope:** Cloud provisioning integrations.

**Acceptance criteria:**

- [ ] EC2 instances and Azure VMs appear in inventory with derived groupings (region/VPC/tag for AWS; location/RG/tag for Azure).
- [ ] Instances can be launched/terminated and lifecycle-managed (start/stop/reboot/etc.).
- [ ] Resource discovery returns current options.
- [ ] Journal is populated from CloudTrail / Activity Log via realtime queries.
- [ ] Vigil-initiated provisioning correlates with the resulting cloud event.
- [ ] Authentication mechanisms (access key, role assumption, SSO; SPN, managed identity) work.
- [ ] Per-tag scoping in RBAC works.

**Required tests:** End-to-end provisioning flow; cross-account scenarios; tag-scoped RBAC; CloudTrail correlation.

## 20.13 Feature Set 12 — MCP Server

**Scope:** Read-only MCP tools for AI agents. CE feature.

**Acceptance criteria:**

- [ ] MCP server exposes the initial tool catalog ([section 17.1.5](17-ai-features.md#1715-tool-catalog-initial-set)).
- [ ] Tool responses are structured, paginated, and token-efficient.
- [ ] RBAC is enforced on MCP tool access — same model as the web UI.
- [ ] Per-principal rate limiting works (per-node enforcement is acceptable and documented).
- [ ] Tools don't flood upstream APIs (caching works correctly).
- [ ] An external MCP-capable client can discover and invoke the tools.

**Required tests:** Tool response shape correctness; RBAC enforcement at the MCP surface; rate limit behavior; cache scope per principal.

## 20.14 Feature Set 13 — AI-Assisted Inference

**Scope:** Contextual analysis buttons, AI-generated reports. CE feature.

**Acceptance criteria:**

- [ ] Bring-your-own-keys configuration works for at least: OpenAI, Anthropic, generic OpenAI-compatible.
- [ ] Contextual analysis features ([section 17.2.3](17-ai-features.md#1723-feature-set-initial)) work end-to-end.
- [ ] AI features are gracefully absent when no LLM key is configured.
- [ ] All AI inputs respect RBAC — no data leakage across users or beyond the requester's scope.
- [ ] Secret redaction uses structured annotation first; regex backstops cover documented patterns.
- [ ] Per-feature disable and global disable both work.
- [ ] Token usage is reported per invocation.

**Required tests:** RBAC scoping in prompt construction; structured redaction correctness; regex backstop coverage; gracefully-absent state.

## 20.15 Feature Set 14 — OIDC Authentication (CE)

**Scope:** Single-IdP OIDC authentication for the Community Edition. Covers the self-hosted team case (Google Workspace, GitHub, Keycloak, Azure AD via OIDC). Deliberately does not include SAML, LDAP, multi-IdP, or wildcard group patterns — those are EE capabilities (FS EE-1).

**Acceptance criteria:**

- [ ] A single OIDC provider can be configured via the admin UI.
- [ ] Users can authenticate via the configured OIDC provider.
- [ ] JIT provisioning creates a user record on first successful OIDC login.
- [ ] Literal (exact-match) group-to-role mappings correctly assign permissions on login and on administrator-triggered "refresh user."
- [ ] Default role for unmapped users works (configurable to "deny access").
- [ ] Local users continue to work alongside OIDC (`AUTH-055`).
- [ ] Break-glass local access works when the OIDC provider is unavailable.
- [ ] Attempting to configure a second OIDC provider in CE is rejected with a clear "EE feature" message (or the UI hides the option).

**Required tests:** End-to-end OIDC login flow; literal group-to-role mapping correctness; OIDC outage + local auth continuity; rejection of multi-IdP configuration.

## 20.16 Phase 2 — Enterprise Edition

Phase 2 delivers EE features in priority order. Each feature set ships as an incremental enterprise release; CE continues to receive bug fixes and new integration plugins independently.

| Feature Set | Scope |
|-------------|-------|
| **FS EE-1** — Enterprise External Authentication | SAML 2.0; LDAP/AD bind + search; multi-IdP OIDC coexistence; group-to-role wildcard patterns; IdP group re-evaluation on every login with additive multi-group resolution; local-auth disable capability |
| **FS EE-2** — High Availability | libcluster; distributed PubSub; session affinity; zero-downtime deploys |
| **FS EE-3** — Approval Workflows | Action queuing; multi-approver; expiry; approval audit |
| **FS EE-4** — Advanced Audit & Compliance | SIEM export (JSON/CEF); scheduled export; tamper-evident signatures |
| **FS EE-5** — Scheduled Executions | Cron scheduling; schedule history; RBAC-at-execution-time; overlap prevention |
| **FS EE-6** — Outbound Webhooks | Event-driven delivery; retry/backoff; signed payloads |
| **FS EE-7** — Custom Dashboards | Widget catalog; shareable dashboards; per-dashboard access control |
| **FS EE-8** — Multi-tenancy | Tenant isolation; per-tenant config; MSP mode |

**EE phase gate (per feature set):** Each EE feature set ships when its acceptance criteria pass and the license enforcement integration is validated. EE releases are independent of CE releases — CE does not block on EE delivery.

See [`docs/specs/editions.md`](../editions.md) for the full CE/EE commercial and architectural rationale.

## 20.17 Cross-cutting work

The roadmap above describes *feature sets*. The following cross-cutting concerns **MUST** be addressed in parallel and **MUST NOT** be deferred to a later phase:

| ID | Requirement |
|----|-------------|
| `ROAD-101` | Performance testing at the 10,000-node target **MUST** begin from Feature Set 4 onward, validating the platform at scale as integrations are added. |
| `ROAD-102` | Resilience testing (circuit breaker behavior, timeout enforcement, plugin isolation) **MUST** be exercised from Feature Set 4 onward. |
| `ROAD-103` | The integration status dashboard **MUST** be functional from Feature Set 4 — administrators need to see what's healthy as they configure integrations. |
| `ROAD-104` | The audit trail **MUST** be functional from Feature Set 3 — every subsequent feature set adds to the audit surface, not the audit foundation. The audit-first ordering requirement (`RBAC-305`) **MUST** be implemented in FS 3, before any feature set introduces irreversible side effects (first occurrence: FS 2 SSH execution — which therefore inherits an audit-ordering dependency on FS 3 RBAC infrastructure; executions in FS 2 record to a minimal local audit log until FS 3 lands). |
| `ROAD-105` | The contract conformance test suite **MUST** evolve in step with the contract — every contract change is paired with conformance updates. |
| `ROAD-106` | Cold-start cache warming (`CACHE-009`) **MUST** be implemented no later than Feature Set 4, the first feature set exposing minutes-scale TTLs that make cold starts user-visible. |
| `ROAD-107` | The in-flight execution durability requirement (`EXEC-106`) **MUST** be implemented no later than Feature Set 5, the first feature set introducing long-running executions. Feature Set 2 SSH execution operates under a documented known limitation (output lost on restart) until FS 5. |

## 20.18 Acceptance gates per phase

The following milestones gate phase completion:

### 20.18.1 Phase 1 complete (CE)

Feature Sets 1 through 14 complete + cross-cutting concerns tracked. The system can:
- Manage SSH, Bolt, Ansible, and Puppet inventories with full unified-inventory linking
- Execute commands across all three execution integrations with streaming output
- Read full Puppet depth: facts, configuration (Hiera, catalogs, environments), events, reports
- Provision Proxmox VMs / containers, AWS EC2 instances, Azure VMs
- Maintain a node journal with manual notes
- Authenticate users locally or via a single OIDC provider with full RBAC including granular permissions and literal group-to-role mapping
- Expose MCP tools to external AI agents with per-principal rate limiting
- Provide embedded AI-assisted inference with bring-your-own-keys
- Survive integration failures with graceful degradation and circuit breakers
- Operate at 10,000 nodes within performance targets on a single node

### 20.18.2 Phase 2 — Enterprise Edition

Feature Sets EE-1 through EE-8 deliver enterprise features as an independent stream. Each feature set is independently releasable and gated by its own acceptance criteria.

### 20.18.3 Phase 2 partial — additional Priority 2 integrations

Priority 2 integration plugins (per [section 10.2](10-priority-2-3-integrations.md#102-priority-2--notes-per-integration)) **MAY** be implemented in any order after Phase 1 CE completion. Each plugin **MUST** ship through its own feature set with acceptance criteria specific to that plugin. Priority 2 integrations are CE unless the individual plugin's capability is identified as governance/enterprise in nature and explicitly marked for EE in a future scope amendment.

## 20.19 Prioritization decisions worth noting

A few non-obvious sequencing choices in the roadmap above:

- **SSH before Puppet (FS 2 vs FS 4)** — SSH is the simplest non-trivial integration. It validates the plugin contract end-to-end against a real external system before the more complex Puppet integration is started.
- **Authentication before deep Puppet (FS 3 vs FS 6)** — Once read access exists in FS 4, RBAC must be enforceable. Adding RBAC after Puppet's full depth would invite gaps.
- **Bolt before deep Puppet (FS 5 vs FS 6)** — Bolt is small and validates the *execution* side of the plugin contract before the heavier Puppet feature set lands.
- **Ansible after deep Puppet (FS 7 vs FS 6)** — Validates the plugin contract's generality across two execution integrations and one deep configuration integration.
- **Journal before unified inventory (FS 8 vs FS 9)** — Journal mechanics are simpler and validate event extraction before the more delicate linking work.
- **OIDC in Phase 1 (FS 14), SAML/LDAP in Phase 2 (FS EE-1)** — Generic single-IdP OIDC is cheap to implement and essential for small-team adoption. SAML and LDAP carry substantially more operational surface (metadata exchange, certificate rotation, directory bind semantics) that small teams do not need and that is properly priced as an enterprise feature.
- **MCP and AI in Phase 1 (FS 12–13)** — Pulled forward from the original roadmap because these features are core differentiators for the AI-native tooling wave. They depend on a stable data model (delivered by FS 8–9) so they land after, not before, the unified inventory and journal are complete.

---

[← Previous: Non-Functional Requirements](19-non-functional-requirements.md) | [Next: Future Considerations →](21-future-considerations.md)

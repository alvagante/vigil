# Vigil — Edition Strategy: Community vs Enterprise

**Document version:** 1.0  
**Status:** Draft  
**Audience:** Product, engineering, commercial strategy

---

## 1. Philosophy

Vigil is released under AGPL v3 as the **Community Edition** (CE). A separate **Enterprise Edition** (EE) provides additional features sold commercially. The split must satisfy three constraints simultaneously:

1. **CE must be genuinely useful** — not cripple-ware. A small or medium infrastructure team must be able to run Vigil in production indefinitely on CE alone without hitting artificial limits.
2. **EE must be genuinely necessary** — enterprises and MSPs must hit CE's boundaries organically (not be blocked by artificial caps), and EE must solve real problems they have at that scale.
3. **The split must be maintainable** — one team, one codebase. Enterprise features cannot require a parallel development track.

The guiding question for every feature placement: *"Would a self-hosted team of five, running their own Vigil instance, ever need this?"* If yes → CE. If it requires an identity provider, organizational governance, multi-org isolation, or compliance auditing → EE.

---

## 2. Feature Split

### 2.1 Community Edition (open source, AGPL v3)

Everything a self-hosted ops team needs to run Vigil in full production:

| Area | Features included in CE |
|------|-------------------------|
| **Platform** | Plugin framework and SDK; full plugin lifecycle; contract conformance suite |
| **Authentication** | Local username/password auth; **OIDC** authentication (single IdP, generic OIDC provider covering Google/GitHub/Keycloak/Azure-AD-via-OIDC); session management; API tokens; break-glass access |
| **Authorization** | Full RBAC (roles, permissions, assignments); per-integration scoping; per-target/per-command granular permissions; default built-in roles; **direct (literal) OIDC group-to-role mapping** |
| **Audit** | Append-only audit trail with full action attribution; local retention policy; UI audit viewer |
| **Inventory** | Unified aggregated inventory; cross-source node linking and deduplication; group linking; source attribution; manual link/unlink overrides; conflict resolution view |
| **Integrations** | SSH, Bolt, Ansible, Puppet (full depth: inventory, facts, configuration, events, reports, Hiera, catalog, code deployment), Proxmox, AWS, Azure |
| **Execution** | Remote execution across all execution-capable integrations; streaming output; per-target transcripts; execution history |
| **Journal** | Per-node timeline; global event timeline; manual notes with edit history; live updates; journal retention |
| **MCP server** | Full read-only MCP tool catalog; RBAC-enforced; per-principal rate limiting; AI agent authentication via API token |
| **AI inference** | Embedded AI-assisted inference (BYOK: OpenAI, Anthropic, compatible endpoints); contextual analysis; secrets redacted from prompts |
| **Resilience** | Circuit breakers; per-integration health checks; graceful degradation; stale-data markers; timeout enforcement |
| **Observability** | Telemetry (Prometheus-compatible); structured logging |
| **Deployment** | Mix release; Docker/container deployment; single-binary distribution |

### 2.2 Enterprise Edition (commercial, closed-source extension)

Features needed at organizational scale, in regulated environments, or for managed service providers:

| Area | Features included in EE | Why it belongs here |
|------|--------------------------|---------------------|
| **External authentication (enterprise)** | SAML 2.0 (multi-IdP); LDAP/Active Directory bind + search; **multi-IdP OIDC** (multiple concurrent OIDC providers, e.g. Okta for staff plus an OIDC for contractors); JIT user provisioning beyond OIDC baseline; **group-to-role mapping with wildcard patterns**; **IdP group re-evaluation on login** with additive multi-group resolution; cross-IdP coexistence rules | Enterprises demand SAML and AD. Multi-IdP and wildcard group mapping are organisational-governance features. CE covers the single-IdP OIDC case that small teams actually want (Google, GitHub, Keycloak); EE layers on the enterprise identity surface. |
| **Multi-tenancy** | Multiple isolated tenants on one installation; per-tenant integration configuration; per-tenant RBAC; no data cross-leakage; tenant admin delegation | Meaningless at single-team scale. Critical for MSPs and large organisations with separate business units. |
| **Approval workflows** | Queued approval for high-impact actions (production provisioning, destructive lifecycle ops, code deployment); multi-approver support; expiring approval windows; approval audit trail | Change-management and compliance requirement in regulated environments. Small teams use trust; enterprises use process. |
| **Advanced audit and compliance** | Structured audit export (SIEM-compatible JSON/CEF); scheduled export to object storage; tamper-evident export signatures; compliance-oriented audit views (who changed what when, by role) | SOC 2, ISO 27001, internal compliance programmes. CE's local audit UI is sufficient for small teams; export and tamper-evidence are enterprise compliance requirements. |
| **Scheduled executions** | Cron-style scheduled commands, tasks, playbooks, plans; schedule history; per-schedule RBAC evaluation at execution time; overlap prevention; failure alerting | Recurring operational automation with audit trail. Important at enterprise scale where ad-hoc is insufficient; CE teams can manage this with external schedulers. |
| **High availability** | Active-active BEAM clustering via libcluster; distributed PubSub across nodes; session affinity; shared-nothing scaling | Operationally irrelevant below a certain fleet or team size. Enterprises expect zero-downtime deploys and redundancy. |
| **Outbound webhooks** | Configurable webhook delivery on events (journal entries, execution completion, provisioning state transitions, integration health changes); retry with exponential backoff; signed delivery | Enterprise integration with ITSM/SIEM/alerting pipelines (ServiceNow, PagerDuty, Splunk). CE teams use MCP or manual monitoring. |
| **Custom dashboards** | User-configurable dashboard views; sharable dashboards with per-dashboard access control; pre-built role-specific dashboards (SRE on-call, Audit overview) | Operational reporting required by management layers and NOC teams. CE's fixed views serve engineers well. |
| **Priority support** | SLA-backed support; dedicated onboarding; upgrade assistance | Service, not software. |

### 2.3 Deliberate placement decisions

A few placements worth making explicit:

- **MCP server → CE.** The MCP server is a core differentiator in the AI-native tooling wave. Putting it behind a paywall kills community adoption by AI-forward engineers, who are exactly the audience that generates word-of-mouth. It belongs in CE.
- **AI inference (BYOK) → CE.** Same reasoning. The user brings their own API key; there is no ongoing cost to Vigil from offering this. Locking it to EE would be perceived as hostile.
- **Basic RBAC → CE.** RBAC must be in CE — otherwise CE is insecure and cannot be run in any real environment. EE extends RBAC with IdP-backed group mapping, not with the concept of roles itself.
- **OIDC → CE, SAML + LDAP → EE.** Generic single-IdP OIDC is cheap to implement, covers the "our team uses Google / GitHub / Keycloak SSO" case that every small self-hosted team runs into, and denying it creates a hostile CE experience. SAML and LDAP/AD, by contrast, are enterprise-scale identity integrations with heavier operational surface (IdP metadata management, multi-realm bind, certificate rotation) that small teams do not need. Multi-IdP coexistence, wildcard group-to-role mapping, and IdP group re-evaluation with additive multi-group resolution are organisational-governance features and stay EE alongside SAML/LDAP.
- **Audit trail → CE.** The append-only audit trail is a security primitive, not a commercial feature. EE adds export and tamper-evidence (compliance tooling), not the audit record itself.
- **Scheduled executions → EE.** This one is borderline. It was placed in EE because CE teams have adequate alternatives (external schedulers + Vigil API/CLI), and the full feature — RBAC evaluation at execution time, schedule history, failure alerting — has an enterprise governance flavour. Revisit if adoption data shows CE teams blocked by its absence.
- **Provisioning integrations (Proxmox, AWS, Azure) → CE.** These are operational, not governance features. A small ops team running on Proxmox should not need an enterprise license to manage VMs.

---

## 3. Roadmap Adaptation

The original roadmap (section 20) is restructured into two phases aligned with the edition split. The sequence within each phase is preserved; the phase boundaries shift.

### 3.1 Phase 1 — Community Edition

Phase 1 delivers a complete, production-grade CE. All feature sets are complete when Phase 1 gates pass.

| Feature Set | Scope | Edition |
|-------------|-------|---------|
| **FS 1** — Core Platform + Plugin SDK | Plugin contract, configuration, health, no-op plugin | CE |
| **FS 2** — SSH Integration | First real integration; proves plugin contract end-to-end | CE |
| **FS 3** — Authentication + RBAC | Local auth, sessions, API tokens, roles, permissions, audit trail | CE |
| **FS 4** — Puppet Integration (Inventory + Facts) | PuppetDB inventory, facts, linking, mTLS, scale validation | CE |
| **FS 5** — Bolt Integration | Bolt inventory, command + task + plan execution, streaming | CE |
| **FS 6** — Puppet Integration (Full depth) | Reports, events, catalogs, Hiera, environments, code deployment | CE |
| **FS 7** — Ansible Integration | Ansible inventory, facts, ad-hoc commands, playbooks | CE |
| **FS 8** — Node Journal | Journal storage, event extraction, manual notes, global timeline | CE |
| **FS 9** — Unified Inventory | Cross-integration linking, deduplication, manual overrides, group linking | CE |
| **FS 10** — Provisioning: Proxmox | VM/container lifecycle, journal from Proxmox task log | CE |
| **FS 11** — Provisioning: AWS + Azure | EC2 + Azure VM lifecycle, CloudTrail/Activity Log journal, cloud auth | CE |
| **FS 12** — MCP Server | Read-only MCP tool catalog, RBAC enforcement, rate limiting | CE |
| **FS 13** — AI-Assisted Inference | BYOK LLM inference, contextual analysis, secrets redaction | CE |
| **FS 14** — OIDC Authentication (CE) | Single-IdP OIDC; JIT provisioning; direct (literal) group-to-role mapping; coexistence with local auth | CE |

**Phase 1 gate:** The system supports full CE functionality — all integrations, unified inventory, execution, journal, local + OIDC RBAC, MCP, and AI inference — for a self-hosted single-tenant deployment at the 10,000-node target scale.

> **Roadmap delta from original:** MCP (originally FS 13, Phase 2) and AI inference (originally FS 14, Phase 2) are pulled into Phase 1. A new CE-scoped OIDC feature set (FS 14) is added: single-IdP, direct literal group-to-role mapping, no multi-IdP, no wildcard patterns. Enterprise-grade external authentication (SAML, LDAP, multi-IdP, wildcard group patterns, IdP group re-evaluation with additive resolution) is moved to Phase 2 EE-1. The original phase numbers are retired; feature sets are renumbered accordingly.

### 3.2 Phase 2 — Enterprise Edition

Phase 2 delivers EE features in priority order. Each feature set ships as an incremental enterprise release; CE continues to receive bug fixes and new integration plugins from the community.

| Feature Set | Scope | Edition |
|-------------|-------|---------|
| **FS EE-1** — Enterprise External Authentication | SAML 2.0 (multi-IdP); LDAP/AD bind + search; multi-IdP OIDC coexistence; group-to-role mapping with wildcard patterns; IdP group re-evaluation on login with additive multi-group resolution; break-glass hardening | EE |
| **FS EE-2** — High Availability | libcluster; distributed PubSub; session affinity; zero-downtime deploys | EE |
| **FS EE-3** — Approval Workflows | Action queuing; multi-approver; expiry; approval audit; integration with execution platform | EE |
| **FS EE-4** — Advanced Audit & Compliance | SIEM export (JSON/CEF); scheduled export to object storage; tamper-evident signatures | EE |
| **FS EE-5** — Scheduled Executions | Cron scheduling; schedule history; RBAC-at-execution-time; overlap prevention; failure alerting | EE |
| **FS EE-6** — Outbound Webhooks | Event-driven webhook delivery; retry/backoff; signed payloads; configurable targets | EE |
| **FS EE-7** — Custom Dashboards | Widget catalog; shareable dashboards; per-dashboard access control; pre-built role views | EE |
| **FS EE-8** — Multi-tenancy | Tenant isolation; per-tenant config; tenant admin delegation; MSP mode | EE |

**Phase 2 gate per feature set:** Each EE feature set ships when its acceptance criteria pass and the license enforcement integration is validated. EE releases are independent of CE releases — CE does not block on EE delivery.

---

## 4. Implementation: One Codebase, Two Editions

### 4.1 Architectural approach

The recommended implementation uses a **separate enterprise OTP application** that extends CE via defined extension points — not a license-key gate inside the CE codebase.

This is consistent with Vigil's existing architecture: just as integrations are separate OTP applications (`vigil_integrations_puppet`, `vigil_integrations_bolt`, etc.) that plug into the platform via the plugin contract, enterprise features are a separate OTP application (`vigil_enterprise`) that plugs into the platform via **extension behaviours**.

```
vigil_core         ← CE domain logic (AGPL)
vigil_plugin       ← plugin contract (AGPL)
vigil_web          ← Phoenix/LiveView (AGPL)
vigil_integrations_* ← CE integrations (AGPL)
vigil_auth_oidc    ← CE OIDC provider (single-IdP, literal group mapping) (AGPL)
─────────────────────────────────────────
vigil_enterprise   ← EE features (proprietary, compiled separately)
  vigil_auth_saml
  vigil_auth_ldap
  vigil_auth_enterprise    (multi-IdP coexistence, wildcard group mapping,
                            IdP group re-evaluation — extends vigil_auth_oidc)
  vigil_enterprise_audit
  vigil_enterprise_approvals
  vigil_enterprise_ha
  vigil_enterprise_scheduled
  vigil_enterprise_webhooks
  vigil_enterprise_dashboards
  vigil_enterprise_multitenancy
```

`vigil_enterprise` is not open source. It is distributed as pre-compiled BEAM bytecode to licensed customers. It does not appear in the CE repository.

### 4.2 Extension points in CE

CE defines explicit extension behaviours for everything EE needs to hook into. CE ships with no-op default implementations. EE replaces them.

| Extension point | CE default | EE replaces with |
|----------------|------------|-----------------|
| `Vigil.Auth.Provider` behaviour | Local auth + OIDC provider (single IdP, literal group-to-role mapping) | SAML / LDAP providers; multi-IdP coexistence; wildcard group patterns; additive multi-group re-evaluation |
| `Vigil.Audit.Exporter` behaviour | No-op (audit stays local) | SIEM export, signed export |
| `Vigil.Execution.ApprovalGate` behaviour | Pass-through (no approval required) | Queued approval engine |
| `Vigil.Cluster.Backend` behaviour | Single-node (no clustering) | libcluster HA backend |
| `Vigil.Webhook.Dispatcher` behaviour | No-op | Outbound webhook delivery |
| `Vigil.Scheduler.Backend` behaviour | No-op | Cron-based schedule engine |
| `Vigil.Dashboard.Store` behaviour | No-op (no custom dashboards) | Persistent dashboard engine |
| `Vigil.Tenant.Resolver` behaviour | Default single tenant | Multi-tenant resolver |

CE code never imports from `vigil_enterprise`. `vigil_enterprise` imports from CE. Dependency direction is one way.

### 4.3 License validation

License validation is implemented in `vigil_enterprise` — not in CE. CE has no license-checking code.

The license is an **Ed25519-signed JSON document** delivered as a file mounted at deployment time. It contains:

```json
{
  "licensee": "Acme Corp",
  "valid_from": "2026-01-01",
  "valid_until": "2027-01-01",
  "features": ["saml", "oidc", "ldap", "ha", "approvals", "audit_export", "scheduled", "webhooks", "dashboards"],
  "node_limit": 50000,
  "signature": "<Ed25519 signature over canonical JSON>"
}
```

Key design decisions:

- **Offline-capable.** No phone-home. The license file is checked locally. Critical for air-gapped infrastructure environments (the primary target market).
- **Grace period.** Expired licenses enter a 30-day grace window with UI warnings before features are disabled. No production outages on billing delays.
- **Node limit is advisory, not hard-blocking.** Exceeding the licensed node count triggers warnings and support outreach; it does not break the running system. Operators are not punished for organic infrastructure growth.
- **Feature-granular.** A license can include any subset of EE features. Customers license what they use.
- **Verification at startup + periodic re-check (daily).** Not per-request — the hot path does not touch license validation.
- **Development mode.** A development license (hardcoded, all features, no expiry, node limit 50) ships with the EE package for local development without a real license file.

### 4.4 Build and distribution

| Target | Distribution method |
|--------|---------------------|
| CE | GitHub public repository; Mix hex packages; Docker Hub image |
| EE | Private Hex repository (authenticated); private Docker registry; pre-compiled BEAM artifacts |

The CE Docker image and CE Mix release contain no EE code. EE is a separate image layer / separate release package that customers install on top of a CE base.

Customers configure which edition they are running by the presence or absence of the `vigil_enterprise` OTP application and the `VIGIL_LICENSE_FILE` environment variable. CE deployments do not require either.

### 4.5 What CE users see for EE features

When a user in a CE deployment navigates to an area where an EE feature would appear:

- **Auth configuration page:** SAML/OIDC/LDAP sections are not shown. Local auth configuration is the only option presented.
- **Execution flow for approval-gated environments:** No approval UI exists. Executions submit immediately (CE behaviour).
- **Audit page:** Export button is not present. Audit log is viewable but not exportable.

CE does not show "upgrade to EE" prompts or disabled UI elements with lock icons. Missing EE features are simply absent — the CE user experience is not degraded by awareness of a paywall. This is a deliberate UX policy: CE users should never feel they are using a limited product.

---

## 5. Community Guarantees

To maintain trust with the open source community:

| Guarantee | Detail |
|-----------|--------|
| **CE is and stays AGPL v3** | The CE codebase license does not change without a public deliberation process. |
| **CE receives all bug fixes** | Security patches and bug fixes ship to CE first, without delay. EE is never used as a reason to withhold a CE fix. |
| **CE integrations are never locked** | Integration plugins (including all plugins built for Phase 1 and future community plugins) remain CE. EE does not gate integrations. |
| **Plugin contract is stable and public** | Community plugin authors build on the same contract as EE. There is no privileged internal API for EE integrations. |
| **EE source is not obfuscated** | EE BEAM artifacts are compiled but not obfuscated. Licensed customers who need to audit the EE code for security purposes can request source review under NDA. |

---

[← Back to PRD index](prd/00-index.md)

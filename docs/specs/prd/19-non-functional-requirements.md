# 19. Non-Functional Requirements

This section consolidates cross-cutting properties the system must exhibit. Many of these are restated or refined elsewhere; this section is the canonical reference and the home of requirements that don't fit neatly into a single feature area.

## 19.1 Performance at scale

| ID | Requirement |
|----|-------------|
| `NFR-001` | The system **MUST** support inventories of up to 10,000 nodes without functional degradation. |
| `NFR-002` | First-page render of any list view at the target scale, given a healthy primary source, **MUST** complete within 2 seconds. |
| `NFR-003` | Aggregation operations **MUST** complete within 5 seconds at the target scale, with progressive results allowed (fast sources first, slow sources later). |
| `NFR-004` | The system **MUST** sustain 5 concurrent active users without queuing read requests. |
| `NFR-005` | The system **MUST** sustain 100 concurrent streaming executions without dropping output. |
| `NFR-006` | Per-request latency at the API surface **MUST** have a P95 under 500 ms for cache-hit reads at the target scale. |
| `NFR-007` | The system **MUST NOT** scale aggregate latency linearly with the number of integrations — adding integrations **MUST NOT** make the inventory page slower than its slowest source. |
| `NFR-008` | The system **MUST** apply request deduplication: identical concurrent requests for the same data result in a single upstream call. |
| `NFR-009` | The system **MUST** apply pagination to every list endpoint and **MUST NOT** rely on full-set materialization in any user-facing flow. |
| `NFR-010` | Performance regressions of more than 20% on any of the targets above **MUST** block release. |

## 19.2 Reliability and availability

| ID | Requirement |
|----|-------------|
| `NFR-101` | The system **MUST** survive transient external service outages without losing data. |
| `NFR-102` | The system **MUST** survive transient network failures without crashing or requiring manual intervention to recover. |
| `NFR-103` | Persistent data (journal entries, executions, audit trail, configuration) **MUST** survive process restart. |
| `NFR-104` | The system **MUST** support graceful shutdown — in-flight operations are allowed to complete or terminate cleanly within a configured deadline. |
| `NFR-105` | The system **MUST** support rolling upgrade where multiple instances are deployed (no requirement that the system itself enforce HA, but the design **MUST NOT** preclude it). |
| `NFR-106` | The system **MUST** detect and log internal errors with sufficient detail for post-mortem analysis. |

## 19.3 Security

### 19.3.1 Authentication and credential handling

| ID | Requirement |
|----|-------------|
| `NFR-201` | Credentials (passwords, tokens, certificates, API keys) **MUST** be stored with a documented protection mechanism: encrypted at rest, never logged, redacted in UI displays. |
| `NFR-202` | The system **MUST** rate-limit authentication attempts per user and per source IP. |
| `NFR-203` | The system **MUST** support account lockout policy after N consecutive failed attempts within a window, with administrator unlock. |
| `NFR-204` | Sessions **MUST** support configurable absolute lifetime and idle timeout. |
| `NFR-205` | Credential rotation (API tokens, IdP secrets, integration credentials) **MUST** be possible without application restart. |
| `NFR-206` | The system **MUST** support secure transport (TLS) for all external endpoints and **MUST NOT** allow plaintext transport in production configurations. |

### 19.3.2 Authorization

| ID | Requirement |
|----|-------------|
| `NFR-301` | Every action exposed by any surface (web UI, API, MCP, CLI) **MUST** be governed by RBAC. There is no "system action" path that bypasses RBAC. |
| `NFR-302` | RBAC enforcement **MUST** occur server-side. Client-side hiding of unavailable actions is presentation, not security. |
| `NFR-303` | Privilege escalation paths **MUST** be reviewed in design — granting a role permission X **MUST NOT** implicitly grant Y. |

### 19.3.3 Data protection

| ID | Requirement |
|----|-------------|
| `NFR-401` | The system **MUST** redact secrets from logs, error messages, audit trails, AI inputs, and UI displays. |
| `NFR-402` | The system **MUST NOT** transmit credentials to upstream tools beyond what those tools require. |
| `NFR-403` | The system **MUST NOT** retain copies of upstream-provided sensitive data beyond what is needed for its features. |
| `NFR-404` | Backups (where they exist) **MUST** be protected at rest with the same protections as the primary data store. |

### 19.3.4 Network security

| ID | Requirement |
|----|-------------|
| `NFR-501` | The system **MUST** verify TLS certificates of upstream tools by default. Skip-verify modes **MAY** be exposed for development with prominent warnings. |
| `NFR-502` | The system **MUST** support deployment behind a reverse proxy / TLS terminator. The system itself **SHOULD** support direct TLS termination as well. |
| `NFR-503` | The system **MUST** support outbound HTTP proxy configuration for environments where direct internet access is restricted. |

### 19.3.5 Audit and compliance

| ID | Requirement |
|----|-------------|
| `NFR-601` | The audit trail **MUST** capture: authentication events, RBAC changes, configuration changes, executions, provisioning actions, manual journal edits, MCP tool invocations. |
| `NFR-602` | Audit entries **MUST NOT** be modifiable. |
| `NFR-603` | Audit retention **MUST** be configurable separately from journal retention (audit usually retained longer). |
| `NFR-604` | The system **MUST** support audit export for compliance review. |

## 19.4 Extensibility

| ID | Requirement |
|----|-------------|
| `NFR-701` | Adding an integration **MUST NOT** require modifications to the platform core. The plugin contract is the only API. |
| `NFR-702` | Adding a permission, role, or capability dimension **MUST NOT** require database schema migrations beyond the established migration story. |
| `NFR-703` | The plugin contract **MUST** be versioned independently of the platform application. |
| `NFR-704` | The platform **MUST** publish a stable, versioned plugin contract specification that community authors can target. |
| `NFR-705` | Extension points (new MCP tools, new AI features, new integration types) **MUST** be additive — adding them **MUST NOT** break existing functionality. |

## 19.5 Caching strategy (consolidated)

| ID | Requirement |
|----|-------------|
| `NFR-801` | The system **MUST** cache derived data (inventory, facts, configuration) per integration with TTLs declared by each plugin and overridable per integration. |
| `NFR-802` | Caches **MUST** support manual invalidation per integration, capability, and node. |
| `NFR-803` | Caches **MUST** be invalidated by webhook where integrations publish change notifications (e.g., Puppet code-deploy events). |
| `NFR-804` | Cache keys **MUST** be scoped to the requesting principal's permission scope to avoid cross-permission leakage. |
| `NFR-805` | Cache size **MUST** be budgeted per integration with documented eviction policy when the budget is exceeded. |
| `NFR-806` | Stale cache data **MUST** be served when the upstream is unhealthy, with explicit staleness markers in the UI. |

## 19.6 Operational requirements

### 19.6.1 Configuration management

| ID | Requirement |
|----|-------------|
| `NFR-901` | The system **MUST** load configuration from a single, authoritative source. |
| `NFR-902` | Configuration **MUST** be validated at startup with clear, actionable errors. |
| `NFR-903` | Configuration **MUST** support reload without full application restart where possible. |
| `NFR-904` | Configuration changes **MUST** be auditable. |

### 19.6.2 Logging and metrics

| ID | Requirement |
|----|-------------|
| `NFR-1001` | The system **MUST** produce structured logs at multiple severity levels with consistent field naming. |
| `NFR-1002` | The system **MUST** expose internal metrics suitable for external monitoring: request rates, error rates, latency percentiles, cache hit rates, integration call counts, plugin resource usage. |
| `NFR-1003` | The system **MUST** offer a health-check endpoint suitable for load balancers. |
| `NFR-1004` | Logs **MUST NOT** contain credentials, tokens, or secrets. |
| `NFR-1005` | The system **MUST** rate-limit log volume per integration to prevent disk exhaustion. |

### 19.6.3 Backups and disaster recovery

| ID | Requirement |
|----|-------------|
| `NFR-1101` | Persistent data (journal, executions, configuration, audit trail) **MUST** be backupable through standard mechanisms appropriate to the chosen persistence layer. |
| `NFR-1102` | The system **MUST** support restoration from backup with a documented recovery procedure. |
| `NFR-1103` | Cached / derived data **MUST NOT** require backup — it is reconstructible from the upstream sources. |

### 19.6.4 Upgrades

| ID | Requirement |
|----|-------------|
| `NFR-1201` | The system **MUST** support upgrade with an automated migration path for persistent data. |
| `NFR-1202` | Plugin contract version compatibility **MUST** be checked on upgrade — incompatible plugins **MUST** be flagged before they are loaded. |
| `NFR-1203` | Downgrade **MAY** be supported but is not a guaranteed property. The system **MUST** document downgrade limitations clearly. |

## 19.7 Documentation

| ID | Requirement |
|----|-------------|
| `NFR-1301` | The system **MUST** ship with: an installation guide, a configuration reference, a per-integration setup guide, a plugin contract specification for community authors, an API reference, a security and operations guide. |
| `NFR-1302` | Documentation **MUST** be versioned alongside the application and **MUST** correspond to the shipped behavior. |
| `NFR-1303` | The system **MUST** provide in-product help — field-level help in configuration UIs, contextual hints in user-facing flows. |

## 19.8 Localization and accessibility

| ID | Requirement |
|----|-------------|
| `NFR-1401` | The system's UI **MUST** meet WCAG 2.1 Level AA accessibility standards. |
| `NFR-1402` | The architecture **MUST NOT** preclude future localization to additional languages. |
| `NFR-1403` | The system **MUST** display all timestamps with timezone disambiguation. |
| `NFR-1404` | The system **MUST** support keyboard-only operation for all primary flows. |

## 19.9 Browser support

| ID | Requirement |
|----|-------------|
| `NFR-1501` | The web UI **MUST** function correctly on the current and previous major versions of mainstream browsers (Chrome / Edge / Firefox / Safari) on desktop platforms. |
| `NFR-1502` | The web UI **SHOULD** function on tablet form factors but **MUST NOT** be expected to be fully functional on phone-sized viewports in the initial release. |
| `NFR-1503` | The web UI **MUST NOT** require browser plugins, browser extensions, or non-standard runtime environments. |

## 19.10 Resource budgets

| ID | Requirement |
|----|-------------|
| `NFR-1601` | The system **MUST** declare expected resource usage at the target scale (memory, CPU, network) and **MUST** document this as part of the operations guide. |
| `NFR-1602` | The system **MUST** apply per-plugin resource budgets so a misbehaving plugin cannot consume the entire process budget. |
| `NFR-1603` | The system **MUST** apply backpressure (queue, throttle, refuse) when resource budgets are exhausted, rather than crashing. |

---

[← Previous: UI Requirements](18-ui-requirements.md) | [Next: Implementation Roadmap →](20-implementation-roadmap.md)

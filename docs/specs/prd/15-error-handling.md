# 15. Error Handling & Graceful Degradation

The system operates against many external tools, any of which may be slow, broken, or temporarily unavailable. This section specifies how the system responds. The unifying principle: **the user gets the best partial answer the system can produce, with honest markers about what's missing and why.**

## 15.1 Per-integration failure handling

| ID | Requirement |
|----|-------------|
| `ERR-001` | When an integration is unreachable, the system **MUST** continue serving data from all other integrations. |
| `ERR-002` | Cached data from a failed integration **MUST** still be served, with a clear staleness indicator showing the last successful sync time. |
| `ERR-003` | The UI **MUST** clearly indicate which integrations are healthy, degraded, or unavailable on every screen where their data appears. |
| `ERR-004` | Integration failures **MUST NOT** produce user-facing error pages. They **MUST** produce partial results with explanations. |
| `ERR-005` | The system **MUST NOT** retry against an integration whose circuit breaker is open. The user-visible request **MUST** complete with the breaker-open marker rather than waiting. |

## 15.2 Degraded state

An integration may be partially functional — some capabilities work, others do not.

| ID | Requirement |
|----|-------------|
| `ERR-101` | The system **MUST** track per-capability health, not just per-integration. |
| `ERR-102` | Degraded integrations **MUST** report which capabilities are working and which are failing. |
| `ERR-103` | UI sections backed by failing capabilities **MUST** indicate the failure with diagnostics, while sections backed by healthy capabilities of the same integration **MUST** continue to render normally. |
| `ERR-104` | Health checks **MUST** distinguish: total unreachability, partial unavailability, authentication failure, authorization failure, rate limit, malformed response, slow response. Each diagnostic **MUST** carry an actionable hint where available. |

## 15.3 Timeout behavior

| ID | Requirement |
|----|-------------|
| `ERR-201` | Each integration **MUST** have a configurable timeout for API calls. Defaults are documented per integration. |
| `ERR-202` | Aggregation operations (e.g., unified inventory, global journal) **MUST NOT** wait for the slowest source. Fast sources return immediately; slow sources are included when ready or skipped on timeout. |
| `ERR-203` | The UI **MUST** indicate when results are incomplete due to timeouts: "3 of 4 sources responded; PuppetDB timed out — retry?". |
| `ERR-204` | Timeouts **MUST** be reported separately from errors — a timeout means "no answer in time," not "answer was no." |
| `ERR-205` | Timeouts **MUST** not consume the timeout budget of other operations. Per-source timeouts are independent. |

## 15.4 User communication

The error model is dictated by the user's job: they need to know **what failed**, **why**, and **what they can do**.

| ID | Requirement |
|----|-------------|
| `ERR-301` | Error messages **MUST** be actionable: what failed, why (when the system can determine it), and what the user can do (retry, check configuration, contact admin). |
| `ERR-302` | Error messages **MUST NOT** expose stack traces, internal identifiers, secret values, or other implementation detail to the user. (Detailed diagnostics are accessible to administrators in the integration status dashboard and logs.) |
| `ERR-303` | Transient errors (network blips, rate limits) **SHOULD** be retried automatically with backoff per [section 11.6](11-platform-requirements.md#116-resilience). |
| `ERR-304` | Persistent errors **MUST** be surfaced in the integration status dashboard with diagnostic detail. |
| `ERR-305` | Authentication failures **MUST** be distinguished from authorization failures in user messaging — "your credentials are invalid" vs. "your role lacks permission" — because the remediation differs. |
| `ERR-306` | When a user action is blocked by RBAC, the message **MUST** identify which permission would be required, without revealing whether the underlying resource exists or its details. |
| `ERR-307` | When an integration responds with a structured error, the system **MUST** preserve the upstream error's content for administrator inspection while presenting a user-friendly summary in the UI. |

## 15.5 Categorization of error sources

Errors **MUST** be categorized to support correct handling and reporting.

| Category | Example | Handling |
|----------|---------|----------|
| Configuration | Missing required field, invalid URL | Block startup or integration enable; report to administrator |
| Authentication | Invalid credentials, expired token | Mark integration unhealthy; preserve cache; alert administrator |
| Authorization (upstream) | Upstream tool rejected on permission grounds | Mark capability degraded; report which permission is missing where the source declares it |
| Transient external | Timeout, 5xx, rate limit | Retry with backoff; trip circuit breaker on consecutive failures |
| Persistent external | 4xx other than auth, malformed response | Mark capability unhealthy; do not retry until administrator intervention |
| Internal plugin | Bug in the plugin code | Mark plugin unhealthy; isolate; report for fix |
| Internal platform | Bug in the platform itself | Page on-call; log with full diagnostic |
| User input | Bad parameters | Reject with field-level message; do not invoke upstream |

| ID | Requirement |
|----|-------------|
| `ERR-401` | Plugins **MUST** classify their errors against this taxonomy when reporting through the standard error contract. |
| `ERR-402` | The platform **MUST** apply category-specific handling — transient external errors are retried, configuration errors are not. |
| `ERR-403` | The administrator-facing error view **MUST** display the category alongside the message so triage is fast. |

## 15.6 Logging and diagnostics

| ID | Requirement |
|----|-------------|
| `ERR-501` | Every error **MUST** be logged with: timestamp, source (integration + capability), category, message, optional structured detail. |
| `ERR-502` | Logs **MUST NOT** contain secrets. Plugins **MUST** redact sensitive parameters before logging. |
| `ERR-503` | Logs **MUST** be searchable by integration, category, and time range from the integration status dashboard. |
| `ERR-504` | A single user-facing error **MUST** correlate to the underlying log records via a correlation identifier visible to administrators. |
| `ERR-505` | The platform **MUST** rate-limit log volume per integration to prevent a misbehaving plugin from filling disk. |

## 15.7 Recovery

| ID | Requirement |
|----|-------------|
| `ERR-601` | Recovery from a failure **MUST** be automatic. The platform **MUST** periodically probe broken integrations and resume normal operation when they recover. |
| `ERR-602` | On recovery, cached data **MUST** be refreshed in the background; staleness markers **MUST** be cleared as fresh data arrives. |
| `ERR-603` | A recovery event **MUST** generate an entry in the system event log (visible to administrators) so flapping is detectable. |
| `ERR-604` | Manual recovery actions (force health check, reset connection pool, reload credentials) **MUST** be available to administrators from the integration status dashboard. |

## 15.8 Cascading failure prevention

| ID | Requirement |
|----|-------------|
| `ERR-701` | One unhealthy integration **MUST NOT** cause others to become unhealthy. The platform's per-plugin isolation guarantees this. |
| `ERR-702` | The platform **MUST** apply per-plugin resource budgets (memory, connection pool, concurrent calls) to prevent a single plugin from starving the rest. |
| `ERR-703` | Health-check failures **MUST NOT** cascade — a slow health-check probe **MUST NOT** delay or fail another integration's probe. |
| `ERR-704` | The platform itself **MUST** apply rate limits and concurrency controls so a flood of user requests cannot exhaust shared resources. |

## 15.9 The "no integrations" state

| ID | Requirement |
|----|-------------|
| `ERR-801` | A fresh installation with no integrations configured **MUST NOT** crash, error, or display blank empty states without context. |
| `ERR-802` | The empty state **MUST** guide the administrator: "no integrations configured — start with one of: Puppet, Ansible, SSH, Bolt." |
| `ERR-803` | Each capability surface (inventory, journal, etc.) **MUST** display its own empty-state message: "no inventory sources are enabled. Enable an inventory-capable integration to begin." |

## 15.10 Plugin contract violations

| ID | Requirement |
|----|-------------|
| `ERR-901` | A plugin that violates its contract (returns malformed data, crashes during a call, exceeds resource budget) **MUST** be quarantined: marked unhealthy, removed from the active integration set, with a clear diagnostic. |
| `ERR-902` | A quarantined plugin **MUST NOT** be re-enabled automatically. An administrator **MUST** explicitly re-enable it after the underlying issue is addressed. |
| `ERR-903` | Plugin-contract violations **MUST** be surfaced prominently — they are platform integrity issues, not transient external failures. |

---

[← Previous: Real-time & Streaming](14-realtime-streaming.md) | [Next: Testing Philosophy →](16-testing-philosophy.md)

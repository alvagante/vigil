# 16. Testing Philosophy

The system's testing strategy is **opinionated**. Tests must verify user-visible behavior and catch real failures. Low-value tests that pass while the product is broken are worse than no tests — they give false confidence and rot.

> **A test is worth writing if it would catch a bug that a user would notice. Otherwise it isn't.**

This is the deciding question for every test in the codebase.

## 16.1 What MUST be tested

### 16.1.1 Integration tests for API endpoints

| ID | Requirement |
|----|-------------|
| `TEST-001` | Every API endpoint exposed by the platform **MUST** have integration tests covering: correct response shape, authentication enforcement, permission enforcement, pagination behavior, error responses. |
| `TEST-002` | Permission tests **MUST** include both positive (permitted action succeeds) and negative (denied action returns the correct error code without leaking information). |
| `TEST-003` | Pagination tests **MUST** include edge cases: empty result, single page, exactly-page-size, cross-page consistency under concurrent inventory changes. |

### 16.1.2 End-to-end tests for critical flows

The user flows in [section 13](13-user-flows.md) define the end-to-end test surface.

| ID | Requirement |
|----|-------------|
| `TEST-101` | Each numbered user flow in [section 13](13-user-flows.md) **MUST** have at least one end-to-end test covering its happy path. |
| `TEST-102` | Critical flows — inventory browsing, command execution with streaming, provisioning, graceful degradation — **MUST** have additional tests covering documented degraded scenarios. |
| `TEST-103` | End-to-end tests **MUST** drive the system through its actual UI (or its actual API for API-only flows), not through internal shortcuts. |
| `TEST-104` | End-to-end tests **MUST** verify user-visible behavior, not internal state — what the user sees on screen, not what the model contains. |

### 16.1.3 Property-based tests for complex logic

| ID | Requirement |
|----|-------------|
| `TEST-201` | **Node identity linking** — given a corpus of synthetic identity tuples (certnames, FQDNs, hostnames, IPs) with intentional ambiguity, the linking algorithm **MUST** produce stable, correct results. Property-based tests **MUST** explore the input space at thousands-of-nodes scale. |
| `TEST-202` | **RBAC permission evaluation** — given a corpus of role definitions, group memberships, and action requests, the permission resolver **MUST** produce correct allow/deny decisions. Property tests **MUST** include role union (additive), wildcard mappings, target scoping, and break-glass scenarios. |
| `TEST-202a` | **RBAC query efficiency** — authorization checks against N targets **MUST** be asserted to issue a constant (bounded) number of data-store queries regardless of N. Tests **MUST** explicitly count queries at N = 1, 10, 100, and 1000 targets and fail on any per-target query pattern. This closes the gap that a functionally correct but linearly-scaling implementation would otherwise pass (`RBAC-108`). |
| `TEST-203` | **Journal event extraction** — given synthetic Puppet reports, AWS CloudTrail events, and monitoring transitions, event extraction **MUST** produce the correct journal entries and grouping. Properties to test: no-op runs produce no entries; events from one report share a group key; steady-state monitoring produces no entries. |
| `TEST-204` | **Cache coalescing** — given concurrent requests for the same cache key, the system **MUST** issue one upstream call. Property tests **MUST** verify under varying concurrency and timing. |
| `TEST-205` | **Shared-cache RBAC filter cost** — tests **MUST** cover cache-hit reads where a broad user warms the shared cache and narrower users with granular scopes read the same entry. The implementation **MUST** prove bounded query count and acceptable latency at the 10,000-node / 10-concurrent-user target. |

### 16.1.4 Resilience tests

| ID | Requirement |
|----|-------------|
| `TEST-301` | The system **MUST** have tests covering: integration becomes unavailable mid-request; circuit breaker trips after N consecutive failures; circuit breaker recovers on probe success; cached data is served with staleness marker when source is unhealthy. |
| `TEST-302` | The system **MUST** have tests for timeout enforcement: per-source timeouts honored; aggregation does not wait for slowest source; CLI integration's wall-clock and idle timeouts terminate runaway processes. |
| `TEST-303` | The system **MUST** have tests for plugin isolation: a misbehaving plugin (returns malformed data, hangs, throws) **MUST NOT** crash the platform. |
| `TEST-304` | The system **MUST** have tests for streaming reconnection: drop the client connection mid-stream, reconnect, verify no output is lost. |

### 16.1.5 Plugin contract conformance

| ID | Requirement |
|----|-------------|
| `TEST-401` | Every first-party plugin **MUST** pass the platform's contract conformance test suite as a prerequisite for release. |
| `TEST-402` | The platform itself **MUST** have tests against the reference no-op plugin to verify the platform-side of the contract. |
| `TEST-403` | The contract test suite **MUST** be exposed for community plugin authors to validate their plugins against. |

## 16.2 What SHOULD NOT be tested

These are explicitly low-value categories. The system **SHOULD NOT** invest test effort here.

| ID | Anti-requirement |
|----|------------------|
| `TEST-501` | Unit tests for trivial CRUD operations **SHOULD NOT** be written. Coverage of the underlying data plumbing comes via integration tests of higher-level operations. |
| `TEST-502` | Tests that only verify mocked API wrappers return what the mock was told to return **SHOULD NOT** be written — they prove nothing about real behavior. |
| `TEST-503` | Pure UI rendering tests without user interaction **SHOULD NOT** be written. UI tests **MUST** drive interactions and verify the resulting state. |
| `TEST-504` | Tests that duplicate what the type system already guarantees **SHOULD NOT** be written. |
| `TEST-505` | "Snapshot" tests that fail when any cosmetic detail changes, with no semantic rationale, **SHOULD NOT** be written. |
| `TEST-506` | Tests of internal state for its own sake **SHOULD NOT** be written. State matters insofar as it produces observable behavior; test the behavior. |

## 16.3 Mocking strategy

| ID | Requirement |
|----|-------------|
| `TEST-601` | Integration tests **SHOULD** prefer real external dependencies (containerized PuppetDB, real local Bolt, a live LocalStack-equivalent for cloud APIs) over mocks. The closer to real, the more valuable the test. |
| `TEST-602` | Where real dependencies are infeasible (e.g., a paid cloud service), the system **MUST** use replay-based fixtures captured from real interactions, not hand-written mocks. |
| `TEST-603` | Hand-written mocks **MAY** be used for unit-level testing of specific decision logic (e.g., circuit breaker state transitions) where the dependency's behavior is well-defined. |
| `TEST-604` | The system **MUST NOT** rely on tests where the test author wrote both the mock and the assertion against the mock — those tests are tautological. |

## 16.4 Performance tests

| ID | Requirement |
|----|-------------|
| `TEST-701` | The system **MUST** have performance tests verifying the scale targets: 10,000-node inventory rendered within 2 seconds; 100 concurrent streaming executions; 10 concurrent users. |
| `TEST-702` | Performance tests **MUST** run as part of the release process. Regressions **MUST** block release. |
| `TEST-703` | Performance tests **MUST** measure latency percentiles (P50, P95, P99), not averages alone. |

## 16.5 Security tests

| ID | Requirement |
|----|-------------|
| `TEST-801` | The system **MUST** have tests verifying RBAC cannot be bypassed at any surface: web UI, API, MCP server, and (future) CLI. |
| `TEST-802` | The system **MUST** have tests verifying secrets are not leaked through logs, error messages, audit trails, or UI displays. |
| `TEST-803` | The system **MUST** have tests for the command allowlist: commands not on the list are rejected; commands on the list with disallowed arguments are rejected; pattern bypasses are rejected. |
| `TEST-804` | The system **MUST** have tests for authentication brute-force protection: rate limiting kicks in; lockout policy applies; logging captures attempts. |

## 16.6 Test data realism

| ID | Requirement |
|----|-------------|
| `TEST-901` | Tests at scale **MUST** use realistic data shapes — node counts, fact sizes, event volumes representative of real deployments. |
| `TEST-902` | The system **MUST** ship with a data generator capable of producing realistic synthetic inventories at the target scale, used by performance and property tests. |
| `TEST-903` | Test fixtures **MUST** include the awkward cases: nodes with missing attributes; nodes with conflicting attributes across sources; groups with overlapping membership; users with multiple group-mapped roles. |
| `TEST-904` | Fact-payload fixtures **MUST** use realistic per-node sizes (typically 50–200 KB of structured facts per node for Puppet, proportionally sized for other sources). Performance tests that serve compressed or abridged fixture payloads **MUST** document the abridgement and **MUST NOT** be used to validate memory or bandwidth budgets at scale. |

## 16.7 Testing in CI

| ID | Requirement |
|----|-------------|
| `TEST-1001` | The system's CI pipeline **MUST** run: unit tests; integration tests against real dependencies (in containers); plugin contract conformance; selected end-to-end tests. |
| `TEST-1002` | A nightly or release-cadence pipeline **MUST** run: full end-to-end suite; performance tests at scale; long-running resilience tests (e.g., 1-hour soak). |
| `TEST-1003` | Test failures **MUST** block merge. The system **MUST NOT** carry "known-failing" tests as a long-term state. |

## 16.8 Testing the testing

| ID | Requirement |
|----|-------------|
| `TEST-1101` | Test code **MUST** be reviewed with the same rigor as production code. |
| `TEST-1102` | Tests that pass against a deliberately broken build **MUST** be removed or fixed — they are providing false confidence. |
| `TEST-1103` | Mutation testing or equivalent techniques **SHOULD** periodically be applied to high-stakes test suites (RBAC, identity linking, resilience) to verify the tests actually catch the bugs they purport to. |

---

[← Previous: Error Handling](15-error-handling.md) | [Next: AI-Assisted Features →](17-ai-features.md)

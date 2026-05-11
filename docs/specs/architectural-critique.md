# Vigil Architectural Critique

---

## What's Right — and Why

**Elixir/Phoenix.** Correct call. Concurrency model fits the workload exactly: long-lived GenServer per integration, per-execution process with ring buffer, PubSub fan-out, OTP fault isolation. The alternative (Go + goroutines) gets you similar concurrency but loses the supervision tree — you'd rebuild a significant part of OTP by hand. The real risk is hiring: the Elixir talent pool is small. For a product expected to be self-hosted by infrastructure teams, this means operators who need to debug a running system will be looking at unfamiliar tooling (`remote_console`, `:observer`, `:sys.get_state/1`). It's the right tradeoff but it's not cost-free.

**Fetch-on-demand journal.** Strongly correct. The alternative — a polling ingest pipeline that writes PuppetDB reports, monitoring transitions, and CloudTrail events to a local store — would triple the operational surface: you'd need per-source pollers with checkpointing, deduplication logic, schema normalization at write time, and a local store that grows without bound. The current design makes the system stateless with respect to external event history, which dramatically simplifies upgrades, migrations, and failure recovery. The 30-60s ETS cache for navigation UX is the right compromise.

**PostgreSQL-only.** Correct at target scale. Redis adds operational complexity for what is here a cache warming layer (ETS already handles that) and a pub/sub layer (PubSub handles that). Elasticsearch for fact search is engineering overkill — pg_trgm covers the use case. The temptation to add these components is real when you're building a monitoring product, but the design correctly resists it.

**ETS caching design.** The `{integration_id, capability}` table per integration, principal-scope-hashed keys, three freshness states, and three invalidation paths is well-designed. The cache is purpose-built for the access pattern. The lookup patterns are point-by-composite-key and scope-prefix scans, not relational joins — raw `:ets` is the right call.

**Plugin conformance test suite as a `use` macro.** Smart. Conformance test is two lines per plugin; it's impossible to accidentally skip. New plugins get tested against the contract automatically. This is the right way to build a plugin ecosystem.

**Testing strategy.** The commitment to real dependencies (containerized Puppet/PuppetDB, real Bolt binary, LocalStack) is exactly right. Mock-heavy suites give false confidence and diverge from production behavior silently. The mutation testing on RBAC and the identity linker is a good call — these are the two places where a subtle bug would be hardest to find and most damaging. The "would this catch a bug a user would notice?" filter on what gets tested is the correct framing.

---

## Tier 1 — Correctness Issues

### 1. N+1 query in `target_matches?` (RBAC evaluator)

Section 08 says the RBAC evaluator calls `Nodes.get(node_id)` per target node to resolve tags for scope checking. An execution submitted against 1000 targets fires 1000 sequential DB queries before the execution rows are even written. This isn't flagged as a known issue anywhere. At 100 targets it's noticeable; at 500 it's user-visible latency before streaming even starts.

Fix is straightforward: `Nodes.get_many(node_ids)` with a single `WHERE id = ANY($1)` query, then resolve from the map. Or pre-load the nodes in the submission pipeline before hitting RBAC. Either way, this needs to be in the design before implementation, because it's the kind of bug that appears in the performance suite at scale and requires a refactor of the RBAC evaluator's interface.

### 2. Audit write atomicity

The current pattern appears to be: take action → write audit entry. If the DB goes down between action and audit write, the action occurred with no record. For an audit trail that satisfies compliance requirements, this is incorrect ordering.

The correct pattern for irreversible actions is: write the audit entry (with `status: :pending`), take the action, mark the audit entry complete — all in a DB transaction where possible, or with the audit write happening first and accepting a "logged but action failed" edge case as the lesser evil. This is a structural design decision that needs to be locked in before the execution pipeline and provisioning pipeline are built, because retrofitting it is invasive.

### 3. Session `last_active_at` write amplification

Section 08 mentions session tracking via `last_active_at`. If this is updated on every authenticated request without debouncing, a power user running the inventory page with live refresh generates continuous writes to the sessions table — the same table the rate limiter is querying on the auth path. The sessions table will become a write hotspot under moderate use.

Debounce to at most once per N minutes (5-10 minutes is standard). The design should specify this; otherwise each implementer makes a local decision and you end up with a correctness disagreement about what "last active" means.

---

## Tier 2 — Missing Specifications That Will Cause Pain

### 4. Multi-node ETS locality for stateless HTTP/MCP

Section 12 correctly identifies that LiveView needs sticky WebSocket connections. But the MCP endpoint and the REST API are stateless HTTP — they route to any node. Node A builds the ETS cache for `{principal:admin, integration:puppet, capability:inventory}` on a warm cache hit. Node B gets the next API request from the same client and misses — goes to upstream PuppetDB. At 2 nodes, cache effectiveness roughly halves. At 5 nodes, the ETS caches for API clients are near-worthless.

This should be acknowledged as a known limitation. If API/MCP cache locality matters (and it does — the MCP use case is agents making frequent identical queries), either: add stickiness at the load balancer for API tokens too (keyed on principal), or accept that API callers will have lower cache hit rates and document accordingly. Neither fix is complex, but ignoring it produces a system that performs well in single-node dev and poorly in multi-node production.

### 5. Plugin trust model — behavioral isolation only

The supervision tree provides fault isolation: a crashing plugin is restarted by its supervisor without taking down the platform. But it provides no data isolation. A plugin running in the same BEAM process can:

- Call `:ets.tab2list(:vigil_permission_cache)` directly — not via the API
- Subscribe to any `Phoenix.PubSub` topic including internal health events
- Call `Vigil.Core.Secrets` module functions if it knows the name
- Inspect any GenServer state via `:sys.get_state/1`

For first-party plugins (Puppet, Bolt, AWS) this is fine. For a community plugin ecosystem — which the plugin framework architecture implies is a goal — this is a significant gap. The mitigation "don't install untrusted plugins" needs to be stated explicitly as a design assumption. If untrusted plugins are ever in scope, the isolation model needs to change: either separate OS processes with message-passing (heavy) or at minimum ETS access control (`:ets.setopts/2` with `{protection, private}`) and documented module boundary enforcement.

### 6. Cold-start cache warming after deploy

Every Mix release deployment is a cold start: all ETS caches empty, circuit breakers reset, health check ring buffers gone. At 10K Puppet nodes with 15-minute cache TTL for inventory and 30-minute for facts, the user-facing experience after a deploy is:

- Inventory loads slowly for ~15 minutes (cache miss → PuppetDB call for each capability)
- Health status shows as `:unavailable` until the first health check completes (30s cycle)
- Any concurrent user load during warm-up hits upstream integrations simultaneously

For an infrastructure management tool where operators expect current state immediately, "wait 15 minutes" after a deploy is an operational problem. This isn't mentioned anywhere in the design.

Options: (a) A post-start Oban job that pre-warms high-priority caches in the background, (b) A TTL-aware snapshot to PostgreSQL on graceful shutdown + restore on boot, (c) Accept the limitation and document it. Option (a) is 1-2 days of work and eliminates the problem.

### 7. LDAP connection pooling

Section 08 mentions LDAP via `Exldap`. `Exldap` wraps `:eldap` which is a single-connection client per process. Under concurrent login load hitting LDAP, you either queue on a single connection (latency spikes) or open per-request connections (expensive LDAP bind per request, connection exhaustion on the LDAP server). This is a well-known pain point in the Elixir ecosystem.

The design should specify either: NimblePool wrapping `:eldap` for pooled LDAP connections, or a GenServer that holds N connections and serves requests from the pool. This needs to be in the design before the LDAP integration is built, not retrofitted.

### 8. Multi-tenancy has no compile-time enforcement

Every table has `tenant_id`. The query that forgets `WHERE tenant_id = $1` leaks data between tenants silently — no crash, no error, wrong data returned. The only mitigation in the current design is "code review" and "integration tests."

For a v1 targeting single-tenant self-hosted deployments, this is low risk. For multi-tenant SaaS (which the design explicitly supports via the zero-UUID default tenant), it's a data isolation vulnerability waiting to manifest. Libraries exist for this: Triplex, or a custom Ecto query macro that injects tenant filtering at the context layer. If multi-tenancy is a first-class concern, it should have first-class enforcement.

### 9. MCP rate limiting is per-node, not per-cluster

Section 10 shows `Hammer.check_rate("mcp:#{principal_id}", 60_000, 120)`. Hammer's default backend is ETS — in-process, per-node. In a 3-node cluster, a principal can make 360 requests per minute before any single node rate-limits them. The design says no Redis and relies on PostgreSQL-only — so the fix isn't Redis-backed Hammer. Options: Postgres-backed Hammer (supported, but adds per-request DB write on the hot auth path), or accept per-node limits and document that rate limits are per-node in multi-node deployments (reasonable for this scale). Either way, the current design silently under-enforces.

### 10. AI redaction is regex-only and brittle

Section 10's `Vigil.AI.Redactor` patterns have gaps:

- The JWT pattern (`eyJ...`) matches any base64-encoded JSON, including node facts that happen to contain base64 data — high false-positive rate.
- The private key regex requires the full PEM block in a contiguous string — if facts are decomposed into fields before redaction, this won't match.
- Only AWS `AKIA` prefix is matched. GCP service account keys (`AIza`), Azure connection strings, Puppet API keys, and custom token formats are not covered.

The schema annotation path (`secret?: true`) is the correct primary mechanism. Regex is a reasonable backstop for unstructured string fields. But the current design treats regex as the primary filter, which will produce both false positives (annoying) and false negatives (dangerous). Invert the priority: structured annotation first, regex only on opaque string values.

---

## Tier 3 — Debatable Choices

### 11. §12.8 CPU spike statement is wrong

"CPU: 2–4 cores typical; spikes to 8 during catalog compilations." Vigil does not compile catalogs. It makes an HTTP POST to Puppetserver and waits for the response. The compilation CPU cost is on Puppetserver. Vigil's CPU during a catalog diff is: one HTTP call per node, one diff computation, one ETS write. The BEAM process is largely waiting on network during this period. This statement will cause operators to over-provision Vigil and under-provision Puppetserver. Fix the text.

### 12. Health check ownership ambiguity

Section 02 describes per-integration HealthWorker GenServers running on 30s timers. Section 05 describes health checks as capability probes managed by the dispatcher. Section 12 lists a `maintenance` Oban queue. It's not clear whether health check probes run as: (a) GenServer timer ticks, (b) scheduled Oban jobs in the maintenance queue, or (c) both. If both, you'll have double-firing. The canonical answer should be specified: GenServer timers are correct here (health checking is a continuous process tied to the integration lifecycle, not a scheduled job), and Oban should only handle maintenance tasks with lower frequency requirements.

### 13. Execution GenServer state is lost across restarts

In-flight execution ring buffers (128KB per target) live in GenServer memory. A mid-flight deploy kills these. The DB gets the final transcript on completion, but streaming state mid-execution is gone. The reconnect test covers LiveView WebSocket reconnection, not process restart. For a deployment mid-large-execution (100 targets, 5 minutes in), this means: all output buffered so far is lost, clients see the terminal as dead.

Mitigation options: (a) drain executions before stopping (SIGTERM handling in the GenServer to flush buffers to DB), (b) persist the ring buffer snapshots to PostgreSQL periodically during long executions, (c) document "deploy during active executions = terminal output lost." Option (a) is the correct approach and should be in the design.

### 14. RBAC property tests don't cover the N+1 query path

The RBAC property test `target scope filter is correctly applied` generates nodes and checks whether the RBAC allows/denies based on tags. The test is correct. But the production implementation calls `Nodes.get()` per target node (see Tier 1, issue 1). The test will pass with a batch-loading implementation or a per-query implementation — it doesn't catch the N+1. The performance test at 10K nodes is where this would surface. Explicitly testing "target_matches? with 1000 targets makes exactly 1 DB query" would close this gap.

### 15. Load test fixtures may not reflect real Puppet data volume

The CI pipeline has a nightly "1-hour load soak" against a "test integration" but it's unclear whether that means a real PuppetDB with 10K node facts or a mock. At 10K nodes, Puppet facts payloads are the dominant memory and network variable — a typical node's facts JSON is 50-200KB. This needs to be a real fixture, not a mock, or the performance suite doesn't catch the actual bottleneck.

---

## Summary

| Issue | Severity | Fix effort |
|---|---|---|
| N+1 in `target_matches?` | High — user-visible latency at scale | Low — batch the query |
| Audit write ordering | High — compliance gap | Medium — pipeline restructure |
| Cold-start cache warming | High — operational degradation after every deploy | Medium — Oban warm-up job |
| Plugin trust model (implicit assumption) | Medium — documents the assumption | Low — add explicit statement |
| Multi-node MCP cache locality | Medium — cache effectiveness at scale | Low — document or add stickiness |
| Session write amplification | Medium — DB hotspot under load | Low — debounce |
| LDAP pooling | Medium — auth latency under load | Medium — NimblePool wrapper |
| AI redaction priority | Medium — false positives and false negatives | Low — change evaluation order |
| Execution state on restart | Medium — output loss during deploy | Medium — SIGTERM drain |
| Health check ownership | Low — double-firing risk | Low — pick one canonical path |
| Multi-tenancy enforcement | Low for v1, High for SaaS | Medium — Ecto query macro |
| MCP rate limit per-node | Low for small clusters | Low — document the limitation |
| §12.8 CPU spike statement | Low — documentation error | Trivial |
| Load test fixture realism | Low — risk of missing perf bottleneck | Medium — real PuppetDB fixture |

The two highest-priority issues to address before implementation starts are the N+1 RBAC query and the audit write ordering — both are interface-level decisions that become expensive to retrofit once the execution pipeline is built around them. The cold-start warming gap is the highest-visibility operational issue post-deploy.

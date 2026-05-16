# ADR-0006: Shared Unfiltered Integration Cache

**Status:** Accepted  
**Date:** 2026-05-15

## Context

Vigil aggregates data from multiple integrations and exposes it through the web UI, API, and MCP server. RBAC includes target scoping: two users may both have access to the Puppet integration, while only one may see production nodes.

Two cache models were considered:

1. **Principal-scoped cache** — cache keys include the requesting principal or the principal's resolved permission scope. This prevents cross-principal reuse unless scopes match exactly.
2. **Shared unfiltered cache** — cache entries store full integration responses keyed only by integration, capability, action, and call arguments. RBAC target filtering happens after cache lookup and before any data leaves the application layer.

The initial design leaned toward principal-scoped keys. The PRD now requires the shared model in `CACHE-006`, `RBAC-107`, and `MCP-203`.

## Decision

**Use a shared, unfiltered integration cache.**

Cache keys do not include principal identity or principal permission scope:

```
{integration_id, capability, action, args_hash}
```

Cache values contain full integration responses with source attribution. Application-layer contexts apply RBAC target-scope filtering before rendering HTML or constructing API/MCP responses. Pagination is applied after RBAC filtering.

RBAC filtering on cached data is not raw rule evaluation per record. For each request, Vigil resolves the request principal into an effective scope set first, then filters cached records using normalized record attributes such as tenant, environment, site, node group, node id, tags, or source integration. The common path must be bounded and membership-check based, not `records x rules` policy interpretation.

The dispatcher still performs a coarse RBAC pre-flight check before invoking a capability: the principal must be allowed to use that capability on that integration at all. Per-target visibility is enforced after the cache lookup.

## Rationale

At the target scale of 10,000 nodes, in-memory target filtering is cheap compared with upstream API calls. Principal-scoped caches multiply memory use and cache misses by the number of distinct users or permission scopes, which is the wrong tradeoff for an admin-focused tool.

This remains true only if effective scopes are compiled before filtering and records expose indexed/filterable attributes. If RBAC evolves toward many highly granular object-level predicates, the shared cache contract still stands, but the filtering implementation must add derived indexes or scoped materialized subsets instead of repeatedly interpreting rules across the full cached result.

The shared model also prevents a subtle pagination problem: if cache entries held paginated slices fetched under a particular user, later users with different scopes would see an incomplete universe. The cache must hold the full integration result so every principal filters and paginates from the same source truth.

Security does not depend on cache key isolation. It depends on a strict invariant: unfiltered cache entries never cross the application boundary. Context functions, API controllers, LiveViews, and MCP tools must construct responses only after applying `Vigil.Core.RBAC.filter_targets/3` or the equivalent scoped query.

## Consequences

- Cache tables must be treated as sensitive internal data. ETS tables should use `:protected` access where practical; plugin processes do not read cache tables directly.
- Every response path that consumes cached integration data must apply target-scope filtering before serialization or render.
- RBAC filters in the cache-hit hot path must resolve the principal's effective scope once per request/session and apply cheap set membership or indexed predicate checks against cached records.
- Implementations must avoid `O(records x rules)` filtering in normal read paths. If granular RBAC makes direct filtering too expensive, add derived indexes or scoped materialized views while keeping the underlying integration cache shared and unfiltered.
- Tests must cover the failure mode directly: an admin warms a shared cache, then a narrower user queries the same data and receives only permitted targets.
- Performance tests must include granular-scope cases, not only administrator-wide visibility.
- Cache sizing must account for full integration results, not paginated slices.
- Cursor pagination is a post-filter operation.
- MCP tools use the same cache entries as the web UI, but construct principal-filtered responses.
- If Vigil later introduces process-level plugin isolation or a distributed cache, the cache contract remains the same: shared integration truth inside the trust boundary, filtered output at the application boundary.

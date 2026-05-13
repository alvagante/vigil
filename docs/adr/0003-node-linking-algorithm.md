# ADR-0003: Node Linking Algorithm — Multi-Attribute Inverted Index

**Status:** Accepted  
**Date:** 2026-05-13

## Context

`INV-110` prohibits quadratic comparison for node linking at 10,000+ nodes and requires indexed attributes. The PRD defines the cascade of linkable attributes (certname → FQDN → hostname → primary IP) but does not prescribe the algorithm.

Node linking is the hardest algorithmic problem in the system and the one most likely to be implemented incorrectly on the first attempt. Without a concrete approach specified, each implementer may reach for the intuitive but wrong solution: for every new node record, compare it against all existing nodes on each attribute. That is O(N × M) per integration refresh, where N is existing nodes and M is newly reported nodes — quadratic in the common case where N ≈ M at scale.

Three approaches were considered:

1. **Full cross-product comparison** — for each incoming node record, scan all existing nodes and compare attributes. O(N²) per refresh. Prohibited by `INV-110`.

2. **Database-level join on attributes** — issue a SQL join between the incoming batch and the existing node table on each linkable attribute. Scales with index quality; dependent on the query planner; attribute normalization must happen before the join. Viable but couples linking logic to the database schema in ways that complicate rule changes.

3. **Multi-attribute inverted index** — maintain an in-memory map from each known attribute value to the canonical node ID that claims it (`certname → node_id`, `fqdn → node_id`, `hostname → node_id`, `ip → node_id`). Linking an incoming record becomes a sequence of point lookups, not a scan. The index is maintained incrementally as integration caches refresh.

## Decision

**Multi-attribute inverted index, updated incrementally on integration cache refresh.**

The index is a set of maps, one per linkable attribute type, from normalized attribute value to canonical node ID:

```
certname_index : string → node_id
fqdn_index     : string → node_id
hostname_index : string → node_id
ip_index       : string → node_id
```

When an integration cache refresh delivers a batch of node records:

1. For each incoming record, walk the attribute cascade (certname → FQDN → hostname → IP) and look up each present attribute in the corresponding index map.
2. The first hit identifies the canonical node. If the record carries multiple attributes that hit different canonical nodes, it is a linking conflict — surfaced as a manual review item rather than silently merged.
3. On a miss across all attributes: create a new canonical node record and add all the record's attributes to the index.
4. On a hit: associate the incoming record's integration with the existing canonical node; add any new attributes from this record to the index under the same node ID.
5. When a node is decommissioned (`DM-1106`, `DM-1107`): remove all its attribute claims from the index so that a future node at the same address links fresh.

Attribute values are normalized before indexing (lowercased, stripped of trailing dots for FQDNs, canonicalized for IPs) to prevent false misses from case or formatting differences.

## Rationale

Point lookups in a hash map are O(1). Linking an incoming batch of M records costs O(M × A), where A is the number of attribute types in the cascade (currently 4) — effectively O(M), linear in the batch size, independent of the total number of existing nodes N.

Index maintenance on refresh is also O(M × A): for each record in the incoming batch, update at most A index entries. This is dominated by the cost of the integration API call itself.

The index lives in memory alongside the integration cache. It does not need to survive a process restart in isolation — it can be rebuilt from the persisted node identity records at startup in a single pass.

## Consequences

- The platform maintains index maps as a first-class data structure alongside the node identity store, updated on every integration cache refresh.
- Linking conflicts (incoming record's attributes hit two different canonical nodes) must be surfaced for manual review rather than silently resolved. The linking conflict queue is a required UI element.
- IP index entries are released on node decommission (`DM-1107`); the index maintenance code must handle decommission events.
- Manual link/unlink overrides (`DM-1102`) take precedence over index-derived links; the index must track which claims are override-pinned and skip the cascade for those attributes.
- At startup, the index is rebuilt from persisted identity records before accepting integration cache data. Startup time is O(N × A) in the number of persisted nodes — at 10,000 nodes with 4 attribute types, this is 40,000 index insertions, which is negligible.
- The algorithm handles the IP reuse problem correctly by design: decommission removes the IP claim from the index; the next node reporting that IP gets a fresh entry.

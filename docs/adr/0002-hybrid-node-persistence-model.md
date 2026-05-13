# ADR-0002: Hybrid Node Persistence Model

**Status:** Accepted  
**Date:** 2026-05-13

## Context

The initial PRD (`DM-1101`) stated that inventory is "derived" — queried on demand from source tools, not stored by Vigil. This was the intended design: external tools remain authoritative, Vigil is a convergence view.

However, three other PRD requirements are incompatible with pure live inventory:

1. `DM-001`: Nodes must have a **stable canonical identity** that survives attribute changes (e.g., IP rotation, hostname rename).
2. `DM-601`: Executions must produce Journal entries that **reference a node by a stable ID** — those references must survive the node disappearing from all integrations.
3. Manual linking overrides must be persisted and survive Vigil restarts.

A pure live inventory cannot satisfy any of these: if node records only exist while an integration reports them, there is nothing to reference from a Journal entry once the node is removed from the source.

## Decision

**Hybrid persistence model.** Vigil persists node *identity*; it derives node *data*.

- **Persisted (Vigil is authoritative):** Node canonical ID, known identity attributes per source (certname, FQDN, hostname, IPs), source set, linking metadata, manual link/unlink overrides, decommission flag, first-seen / last-seen timestamps.
- **Derived (source tools are authoritative):** Facts, configuration items, monitoring state, reports, inventory membership, provisioning events, deployment events.

Nodes transition through three identity states: Active → Unreported → Decommissioned. The transition to Decommissioned is always explicit (administrator action); the transition to Unreported is automatic when no integration reports the node.

## Rationale

The distinction maps cleanly to what Vigil originates vs. what it observes:
- Vigil originates identity (it creates the canonical record on first discovery) → persisted.
- Source tools originate operational data → derived.

This also resolves the IP reuse problem: decommissioning a node releases its IP claim, so a new node at the same address is linked fresh.

## Consequences

- The platform's primary data store contains a `nodes` table (or equivalent) with identity records. This is in addition to, not instead of, the live integration queries.
- An "Unreported nodes" administrator view is required so stale nodes surface for action (`DM-1109`).
- Explicit decommission is a new administrator action not present in the original PRD — added as `DM-1106` through `DM-1109`.
- Derived data TTLs and cache invalidation logic do not affect node identity — even with an empty cache, the identity record exists.

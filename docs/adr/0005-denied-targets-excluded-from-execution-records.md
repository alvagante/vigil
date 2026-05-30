# ADR-0005: Denied Targets Excluded from Execution Records

**Status:** Accepted  
**Date:** 2026-05-13

## Context

When a user dispatches an execution against N nodes and RBAC denies some of them, the system must decide what to persist for the denied nodes.

Two models were considered:

1. **Denied nodes get execution records** with outcome `permission_denied`. The execution group summary includes them; they generate journal entries on the target node. The group closes when all records — including denied ones — reach a terminal state.

2. **Denied nodes produce no execution records**. The denial is recorded only in the audit trail. The execution group contains only dispatched nodes.

## Decision

**Denied nodes produce no execution records. The audit trail is the sole authoritative record of denied nodes.**

## Rationale

An execution record's semantic meaning is: *the integration was invoked for this node*. A `permission_denied` outcome is a pre-dispatch rejection — the integration was never called, nothing ran on or toward the target node. Creating a record for something that did not execute conflates two distinct concepts.

The RBAC model compounds the problem: `RBAC-107` restricts journal visibility by target scope. A user who cannot execute against a node also cannot see that node in inventory. If denied nodes produced execution records and journal entries, those records would reference nodes the requesting user cannot see — internally inconsistent with the RBAC model.

The audit trail (`RBAC-109`) is already purpose-built for security accountability: it records the full intended target list, the per-target permission decision, and the set of targets actually dispatched. It is admin-visible, tamper-evident, and independent of the execution record model. Ownership of denied-node information belongs there.

The submitting user already sees denied targets surfaced at dispatch time (`RBAC-102`) — they receive immediate feedback without needing a persistent record in the execution model.

## Consequences

- `DM-601`: Execution records are created only for nodes that were actually dispatched to an integration. A dispatch against 100 nodes where 10 are denied creates 90 execution records.
- The execution group summary counts only dispatched nodes. Denied nodes do not appear in group counts or the execution list view.
- `RBAC-109`: The audit trail entry for the dispatch records the full original target list, each node's permission decision (permitted / denied with reason code), and the dispatched subset. This audit entry is the only place denied nodes are persisted.
- The audit trail requires its own retention policy independent of execution record retention — it must retain denied-dispatch events even after execution records for the same dispatch are purged.
- "Re-run" from history re-dispatches the originally permitted nodes (from the execution group). If the user's permissions have changed since the original run, the new dispatch re-evaluates RBAC at that time — it does not inherit the original permission decisions.

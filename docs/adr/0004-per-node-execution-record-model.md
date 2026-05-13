# ADR-0004: Per-Node Execution Record Model

**Status:** Accepted  
**Date:** 2026-05-13

## Context

Vigil supports executing commands, tasks, and playbooks against multiple nodes in a single user action. Two models exist for persisting this:

1. **Per-job record** — one execution record per dispatch, with the target node set and per-target outcomes embedded as sub-records or a structured column. This is how most orchestration tools model it (Ansible AWX "job" + "job events", Jenkins "build").

2. **Per-node record** — one execution record per target node, with all records from the same dispatch sharing an `execution_group_id`. A dispatch against 100 nodes creates 100 records.

The per-job model was the implied default in the initial PRD (`§12.1.7 Execution` listed "Targets: Set of Nodes targeted" as a single property). This was revisited during design review.

## Decision

**Per-node execution records, grouped by `execution_group_id`.**

Each execution record belongs to exactly one node and one integration. Records from the same dispatch share a stable `execution_group_id` generated at dispatch time. A single-node dispatch produces a group of one.

Transcripts are stored inline per record with a configurable size cap (default 50 MB). When the cap is reached, the transcript is closed with an explicit truncation marker; the record is still saved. External blob storage is not required.

## Rationale

The per-node model aligns with every other per-node data structure in the system:

- `DM-601` already required one journal entry per target node. With per-job records, producing journal entries meant iterating over embedded sub-records. With per-node records, it is a 1:1 relationship.
- The node detail page's execution history is a direct lookup by `node_id`. No join or filter on embedded arrays.
- RBAC target scoping (`RBAC-107`) already evaluates per-node. The execution record model matches the evaluation unit.
- Re-running only failed nodes is natural: filter the group by outcome ≠ `ok`, re-dispatch.

The 50 MB inline cap avoids the operational burden of requiring external blob storage for a self-hosted single-node tool. 50 MB of terminal output represents many hours of continuous output from any realistic command. The truncation marker is explicit — the record is never in an ambiguous state.

## Consequences

- The `executions` table has one row per node per run. A 100-node dispatch inserts 100 rows atomically at dispatch time, all with the same `execution_group_id`.
- The execution list view groups by `execution_group_id` by default, showing aggregate outcome counts per group (e.g., `47 ok / 2 failed / 1 unreachable`). Expanding a group shows per-node rows.
- Re-execution from history operates at two scopes: re-run this node only; re-run the entire group against all original nodes. The UI also offers "re-run failed" against the subset of the group with non-`ok` outcomes.
- Streaming state (`live` / `closed`) is tracked per record, per node. A group's overall streaming state is derived: `live` while any member is live; `closed` when all are closed.
- The `execution_group_id` is the stable external reference for "I ran this action." Group IDs should be URL-safe identifiers that can be shared and deep-linked.
- Nodes denied by RBAC before dispatch do not receive execution records — see ADR-0005.

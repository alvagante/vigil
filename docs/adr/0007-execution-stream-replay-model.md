# ADR-0007: Execution Stream Replay Model

**Status:** Accepted  
**Date:** 2026-05-15

## Context

The PRD requires real-time execution output with strong replay guarantees:

- `STR-103`: a user who joins a stream after it began receives output already produced before joining the live tail.
- `STR-201`: reconnect resumes from the last received position with no lost output.
- `STR-202`: received output positions are acknowledged on a sliding window.
- `STR-204`: long-absent users can retrieve full output from execution history.

ADR-0004 already decides the persistence model: one `executions` row per target node, grouped by `execution_group_id`, with a per-record transcript cap. The remaining question is the live-stream ownership and replay model.

Options considered:

1. **Ring buffer only** — keep recent output in memory and rely on persisted transcript after completion. This is simple but cannot satisfy replay-from-start while the execution is still live.
2. **Database append per chunk** — write every chunk as it arrives, replay from the database. This satisfies replay but creates a high-write hot path and turns terminal output into a database event stream.
3. **External log/blob store** — stream chunks to object storage or a log backend. This adds an operational dependency and is disproportionate for the Phase 1 single-node target.
4. **Per-group live spool** — one Stream GenServer per `execution_group_id`, with a complete per-target in-memory spool while live, plus checkpoints and final transcript persistence.

## Decision

**Use one Stream GenServer per `execution_group_id`, with a complete per-target live spool capped by the transcript limit.**

Each dispatched target still has its own `executions` row and its own PubSub topic:

```
execution_group_id
  ├── execution_id for node A → execution_stream:<execution_id>
  ├── execution_id for node B → execution_stream:<execution_id>
  └── execution_id for node C → execution_stream:<execution_id>
```

The Stream GenServer owns:

- the plugin runner for the group
- a complete ordered spool per target while the group is live
- a small recent ring buffer per target for cheap reconnects
- per-subscriber acknowledgement positions
- periodic checkpoint writes to `executions.partial_transcript`
- final transcript persistence to each per-node `executions` row

New viewers request replay from position `0` and then join the live tail. Reconnecting viewers replay from their last acknowledged position. After the Stream GenServer exits, replay comes from the persisted transcript.

The live spool is bounded by the same uncompressed transcript cap as `DM-604` (default 50 MB per target). When the cap is reached, the stream appends the explicit truncation marker, continues broadcasting live output to current subscribers, and stops adding further chunks to the spool/persisted transcript buffer.

## Rationale

The per-group GenServer matches how execution runners actually behave: Bolt and Ansible often run one command/process for many targets, while producing per-target output. Group ownership also makes abort, checkpoint, and completion coordination straightforward.

The complete live spool is the smallest mechanism that satisfies `STR-103` without introducing a database write per output chunk. The recent ring buffer keeps the common reconnect path fast, while the full spool covers late joins and long-but-still-live reconnects.

Bounding the spool by the transcript cap keeps memory usage predictable and aligns live replay semantics with historical transcript semantics. If output exceeds the cap, the user sees an explicit truncation marker rather than silent loss.

Explicit acknowledgements make reconnect semantics concrete. The server does not infer "received" from broadcast; it tracks what each LiveView says it rendered.

## Consequences

- `execution_group_id` is the runtime stream owner; `execution_id` remains the per-target persistence and PubSub unit.
- Stream memory usage is proportional to live output up to the transcript cap per active target. Concurrency limits must account for this.
- The transcript cap is now both a persistence and live replay boundary.
- LiveView must send batched acknowledgements for rendered output positions.
- Tests must cover late join from position `0`, reconnect from an acknowledged position, transcript-cap truncation, and post-completion transcript replay.
- The design avoids external blob/log dependencies for Phase 1. A future external spool backend can replace the in-memory spool without changing the per-group/per-target contract.

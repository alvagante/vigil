# 14. Real-time & Streaming Requirements

The system has three categories of real-time behavior: **streaming execution output**, **live-updating data** (monitoring, inventory, journal), and **connection resilience**. This section specifies each.

## 14.1 Streaming execution output

### 14.1.1 Latency

| ID | Requirement |
|----|-------------|
| `STR-001` | Output from a remote execution **MUST** appear in the UI within 200 ms of generation on the target node, network latency permitting. |
| `STR-002` | The system **MUST NOT** introduce intermediate buffering that would batch output beyond perceptible latency. Buffering for transport efficiency is permitted as long as the user-perceived latency remains within target. |
| `STR-003` | Per-target streaming attribution **MUST** be preserved when output from multiple concurrent targets is interleaved. |

### 14.1.2 Concurrency

| ID | Requirement |
|----|-------------|
| `STR-101` | The system **MUST** support 100 concurrent streaming executions without dropping output. |
| `STR-102` | Multiple users viewing the same execution **MUST** see the same stream concurrently, with consistent ordering. |
| `STR-103` | A user who joins a stream after it began **MUST** receive the output already produced (replay from start) before joining the live tail. |

### 14.1.3 Reconnection and replay

| ID | Requirement |
|----|-------------|
| `STR-201` | If a user's connection drops during execution, reconnection **MUST** resume from the last received position with no lost output. |
| `STR-202` | The system **MUST** acknowledge received output positions on a sliding window so reconnection knows where to resume. |
| `STR-203` | A user **MAY** disconnect arbitrarily without affecting the server-side execution — the execution **MUST** continue and its full transcript **MUST** be preserved. |
| `STR-204` | A reconnect after long absence (e.g., the user closed their laptop, returned hours later) **MUST** still allow retrieval of the full output via the execution history view, even if the live stream has long since closed. |

### 14.1.4 Persistence

| ID | Requirement |
|----|-------------|
| `STR-301` | Completed execution output **MUST** be fully preserved and retrievable after the stream ends. |
| `STR-302` | Persisted transcripts **MUST** survive application restart. |
| `STR-303` | The system **MUST** record per-execution metadata alongside the transcript: targets, parameters, initiating user, start/end time, exit status. |

## 14.2 Live-updating data

### 14.2.1 Monitoring

| ID | Requirement |
|----|-------------|
| `STR-401` | Monitoring status **SHOULD** update in the UI without manual refresh. |
| `STR-402` | The system **MUST** support push-based updates from monitoring sources where the source provides them (webhook or streaming API). |
| `STR-403` | Where push is unavailable, the system **MUST** support short-polling at an interval configurable per integration (default: 30 seconds). |
| `STR-404` | Monitoring updates **MUST** carry the source's evaluation timestamp so the UI can indicate data freshness. |

### 14.2.2 Inventory changes

| ID | Requirement |
|----|-------------|
| `STR-501` | Inventory changes (new nodes appearing, nodes going offline) **SHOULD** be reflected in the UI within the configured cache TTL. |
| `STR-502` | Where an integration supports incremental change feeds, the system **MUST** prefer those over full inventory re-fetch. |
| `STR-503` | The user **MAY** manually trigger an inventory refresh per integration, bypassing TTL. |

### 14.2.3 Journal

| ID | Requirement |
|----|-------------|
| `STR-601` | Journal entries from external sources **SHOULD** appear without manual page refresh. |
| `STR-602` | The system **MAY** use push notification (websocket-equivalent), short-polling, or hybrid mechanisms; the choice is implementation-level provided the perceived latency requirement is met. |
| `STR-603` | New journal entries **MUST** be ordered correctly relative to existing entries on arrival; the system **MUST NOT** show entries out of chronological order. |

### 14.2.4 Provisioning progress

| ID | Requirement |
|----|-------------|
| `STR-701` | Provisioning progress (state transitions: pending → creating → running → ready) **MUST** be reported in real time. |
| `STR-702` | State transition events **MUST** be sourced from the upstream tool's progress reporting (task log, operation status endpoint) — not from local timer-based heuristics. |
| `STR-703` | A failed provisioning step **MUST** be reported immediately with the upstream tool's error detail, without requiring user-initiated polling. |

## 14.3 Connection resilience

### 14.3.1 Disconnect / reconnect handling

| ID | Requirement |
|----|-------------|
| `STR-801` | The UI **MUST** detect connection loss to the server and present a disconnected state to the user (visible indicator; queued user actions held or rejected with explanation). |
| `STR-802` | The UI **MUST** auto-reconnect with exponential backoff. |
| `STR-803` | On reconnection, the UI **MUST** sync to current state without requiring a full page reload. |
| `STR-804` | Long-running server-side operations (executions, provisioning) **MUST NOT** be affected by UI disconnection. |

### 14.3.2 Long-running operation tracking

| ID | Requirement |
|----|-------------|
| `STR-901` | The system **MUST** allow a user to navigate away from an in-progress execution or provisioning action and return later to view current progress and final result. |
| `STR-902` | Navigation away **MUST NOT** cancel or pause the operation. |
| `STR-903` | The system **MUST** display, on the user's home / dashboard, an indicator of any in-progress operations they have initiated. |

### 14.3.3 Browser tab and session handling

| ID | Requirement |
|----|-------------|
| `STR-1001` | The system **MUST** support multiple concurrent browser tabs from the same user, each maintaining its own UI state without conflict. |
| `STR-1002` | A user authenticated in one tab **MUST** be authenticated in others (shared session). |
| `STR-1003` | Logging out in one tab **MUST** propagate logout to other tabs at next interaction (or sooner, if the system supports cross-tab eventing). |

## 14.4 Stream lifecycle

| ID | Requirement |
|----|-------------|
| `STR-1101` | Each stream (execution, monitoring update, journal feed) **MUST** have a well-defined lifecycle: opened, transmitting, closing, closed. |
| `STR-1102` | The system **MUST** reclaim resources (memory, network connections, server-side handles) within a defined window after stream close. |
| `STR-1103` | The system **MUST** apply backpressure when a slow consumer cannot keep up with stream production — degrading by dropping subscribers (with notification) rather than dropping output. |
| `STR-1104` | Streams **MUST** be cancelable by their initiating user (e.g., abort an in-progress execution). Cancellation **MUST** terminate upstream work where the integration supports it. |

---

[← Previous: User Flows](13-user-flows.md) | [Next: Error Handling →](15-error-handling.md)

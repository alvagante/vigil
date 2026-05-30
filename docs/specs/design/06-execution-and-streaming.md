# 6. Execution & Streaming

This section covers PRD `EXEC-*`, `STR-*`, and the Remote Execution capability contract. The execution platform is where the system's real-time demands concentrate: live output streaming at 200ms, 100 concurrent executions, reconnection without lost output, per-target attribution, and full transcript persistence.

## 6.1 Process model

Per [ADR-0007](../../adr/0007-execution-stream-replay-model.md), each execution group is owned by one GenServer:

```
Vigil.Core.Execution.Supervisor  (DynamicSupervisor)
│
└── Vigil.Core.Execution.Stream  (one per execution_group_id)
      │
      ├── spawns plugin-specific runner (CLI port, API poller)
      ├── buffers output
      ├── broadcasts chunks on PubSub
      ├── persists on completion
      └── decommissions after grace period
```

The GenServer is the single source of truth during an execution group. It owns one runner and one live output spool per dispatched target. LiveView processes subscribe to the per-target streams they need. The MCP server can also subscribe (for future "watch execution" tools). Audit writes happen at start and end.

## 6.2 Execution lifecycle

### 6.2.1 Submission

User submits the execution form. Phoenix controller (or LiveView event) calls:

```elixir
Vigil.Core.Executions.submit(principal, %{
  integration_id: int_id,
  artifact: %{kind: :command, text: "systemctl status nginx"},
  targets: %{node_ids: [...], groups: [...], filter: nil}
})
```

The context follows an **audit-first pipeline** that satisfies `RBAC-305`. Per **ADR-0004** the pipeline produces one `executions` row per dispatched target node, sharing an `execution_group_id`; per **ADR-0005** denied nodes do **not** receive `executions` rows — they appear only in the audit entry.

Ordering:

1. **Resolve targets** — expand groups/filter to a concrete `node_id` list. A single `Nodes.get_many/1` issues `WHERE id = ANY($1)` and the resolved node structs flow through the entire pipeline.
2. **Validate** — per `FLOW-101`: targets are reachable via the integration, RBAC is evaluated **per-target** (`RBAC-102`), command passes the allowlist. The validator returns `{:ok, %{dispatched: [...], denied: [...]}}` where each `denied` entry carries the failing check (`:rbac_scope | :allowlist | :command_pattern`) and a human-readable reason.
3. **Reject** if `dispatched == []` and `denied != []` — no targets passed RBAC; nothing to run. The audit entry is still written with `result: :denied`.
4. **Create the `execution_groups` row** with the full `intended_targets`, `dispatched_count`, and `denied_count`.
5. **Bulk-insert one `executions` row per dispatched target** with `outcome: :running`, `streaming_state: :live`, sharing the `execution_group_id`. `Repo.insert_all/3` with `returning: [:id, :node_id]` returns the per-target IDs needed by the Stream GenServer.
6. **Write the audit entry in `pending` state** — `Audit.write_pending/2` inserts an `audit_entries` row with `result: :pending` and `params.denied_targets` recording the per-node permission decisions (`RBAC-109`). The audit write is in the **same DB transaction** as the group + per-target inserts, so either all land or none do.
7. **Start the Stream GenServer** via `DynamicSupervisor.start_child/2`, keyed on `execution_group_id` — one GenServer owns the entire group's runner, with per-target sub-state.
8. **Finalize the audit entry** — on Stream start, `Audit.finalize/2` flips it to `:success` (the action was initiated). On Stream start failure, the unroll path finalizes `:failure` and updates every dispatched `executions` row's outcome to `:failed_to_start`.
9. **Return** `{:ok, execution_group_id}` to the caller.

```elixir
defmodule Vigil.Core.Executions do
  def submit(principal, submission) do
    Repo.transaction(fn ->
      with {:ok, resolved}      <- resolve_targets(submission.targets),
           {:ok, decisions}     <- Validator.validate(principal, submission, resolved),
           :ok                   <- ensure_any_dispatched(decisions),
           {:ok, group}         <- insert_group(principal, submission, decisions),
           {:ok, executions}    <- insert_per_target_executions(group, decisions.dispatched),
           {:ok, audit_pending} <- Audit.write_pending(principal, group, decisions) do
        {:ok, {group, executions, audit_pending}}
      else
        {:error, :all_denied, decisions} ->
          Audit.write_finalized(principal, :denied, decisions)
          Repo.rollback({:error, :all_denied})
        err -> Repo.rollback(err)
      end
    end)
    |> case do
      {:ok, {group, executions, audit_pending}} ->
        case Execution.Supervisor.start_stream(group, executions) do
          {:ok, _pid} ->
            Audit.finalize(audit_pending, :success)
            {:ok, group.id}
          {:error, reason} ->
            Audit.finalize(audit_pending, {:failure, reason})
            Vigil.Core.Executions.mark_all_failed_to_start(group.id, reason)
            {:error, reason}
        end
      {:error, _} = err -> err
    end
  end
end
```

Why this ordering matters:

- If the process crashes between audit write and Stream start, durable `pending` audit + `running` executions rows remain. A reconciliation job (see §6.2.7 below) flips orphaned `pending` audit rows to `failure` with `reason: :lost_start` after a grace period; a companion sweep marks orphaned `executions` rows as `aborted_by_restart`. The audit trail never has a gap.
- If the DB is unavailable at any point, the transaction rolls back — no group row, no per-target rows, no audit row, no stream. The user sees a clean error.
- If the stream crashes after start but before completion, the audit entry is still `:success` for *submission*; per-target outcome is captured in each `executions.outcome` column and in the per-target journal entries. Submission audit ≠ completion audit.
- Denied targets never produce execution records (`ADR-0005`). The audit entry's `params.denied_targets` is the sole authoritative record. This keeps the execution model semantically consistent: an `executions` row means *the integration was invoked for this node*.

The alternative ordering — start the stream, then write audit — is rejected: a crash between those two steps leaves a side effect (an outbound SSH connection, a remote process spawned, a cloud API call initiated) with no audit record. For an audit trail intended to satisfy compliance requirements (`RBAC-305`, `NFR-601`), that is incorrect.

### 6.2.2 Audit reconciliation

A lightweight Oban cron job runs every 5 minutes in the `maintenance` queue:

```elixir
defmodule Vigil.Oban.Workers.AuditReconciler do
  use Oban.Worker, queue: :maintenance

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -15 * 60, :second)

    from(a in AuditEntry,
      where: a.result == "pending" and a.occurred_at < ^cutoff
    )
    |> Repo.update_all(set: [result: "failure",
                              params: %{reason: "lost_start",
                                        reconciled_at: DateTime.utc_now()}])
  end
end
```

`pending` entries older than 15 minutes are flipped to `failure` with the `lost_start` reason. This ensures the audit trail remains readable and complete — no `pending` forever.

### 6.2.3 Permission validation

Three layers (`EXEC-004`, `FLOW-101`, `RBAC-102`, `RBAC-103`, `RBAC-104`):

```elixir
defmodule Vigil.Core.Executions.Validator do
  def validate(principal, submission) do
    with :ok <- rbac_action(principal, submission.integration_id, submission.artifact.kind),
         :ok <- rbac_targets(principal, submission.integration_id, submission.targets),
         :ok <- allowlist(principal, submission.integration_id, submission.artifact),
         :ok <- reachability(submission.integration_id, submission.targets) do
      :ok
    else
      {:error, reason} -> {:error, reason_with_hint(reason)}
    end
  end
end
```

Each check fails with an actionable reason (`FLOW-101`, `ERR-306`). The layered checks mean rejection happens before any upstream invocation.

### 6.2.4 Stream GenServer

One Stream GenServer per `execution_group_id`. It owns the runner and the per-target buffers; each per-target buffer corresponds to one `executions` row.

```elixir
defmodule Vigil.Core.Execution.Stream do
  use GenServer

  # State
  defstruct [
    :execution_group_id,
    :integration_id,
    :plugin_module,
    :targets,              # %{execution_id => %{node_id, identity, outcome}}
    :runner_ref,           # reference to the plugin runner (port, task)
    spool: %{},            # %{execution_id => complete ordered chunks while live}
    recent_buffer: %{},    # %{execution_id => ring buffer of recent chunks}
    buffer_position: %{},  # %{execution_id => monotonic position}
    subscriber_ack: %{},   # %{subscriber_pid => %{execution_id => last_position}}
    bytes_written: %{},    # %{execution_id => uncompressed bytes; for DM-604 cap}
    finished_targets: %{},
    grace_timer: nil
  ]

  def start_link(args),
    do: GenServer.start_link(__MODULE__, args, name: via(args.execution_group_id))

  def get_buffer(execution_group_id, execution_id, since_position) do
    GenServer.call(via(execution_group_id), {:backfill, execution_id, since_position})
  end

  def ack(execution_group_id, execution_id, subscriber_pid, position) do
    GenServer.cast(via(execution_group_id), {:ack, execution_id, subscriber_pid, position})
  end

  def abort(execution_group_id, principal) do
    GenServer.call(via(execution_group_id), {:abort, principal})
  end
end
```

State lives entirely in the GenServer. LiveView disconnects don't affect it (`STR-203`). The per-target keying by `execution_id` (the per-node row's primary key) means subscribers can address a single target's stream without parsing positional indexes.

### 6.2.5 Buffering, replay, and acknowledgements

`STR-103` requires a user joining a live stream after it began to receive all output already produced before joining the live tail. A short ring buffer alone is insufficient, so each Stream GenServer maintains two per-target structures while the execution is live:

| Structure | Purpose | Lifetime |
|-----------|---------|----------|
| `spool` | Complete ordered chunk list from position `1` onward, capped by the transcript size cap (`DM-604`) plus explicit truncation marker | Live execution + grace window |
| `recent_buffer` | Small ring buffer (default 128 KB) for cheap reconnects from recent positions | Live execution + grace window |

Each chunk gets a monotonic position number:

```elixir
%{1 => {pos_1, "chunk text"}, 2 => {pos_2, "chunk text"}, ...}
```

Replay behaviour:

- **Join from start (`STR-103`)**: a new LiveView calls `get_buffer(group_id, execution_id, 0)` and receives the full live spool before subscribing to the live tail.
- **Reconnect (`STR-201`)**: a reconnecting LiveView calls `get_buffer/3` with its last acknowledged position. If the requested position is still in `recent_buffer`, replay is cheap. If not, replay falls back to the full spool and slices from the requested position.
- **Long absence after close (`STR-204`)**: once the Stream GenServer has terminated, replay comes from the persisted transcript in PostgreSQL.

The spool is bounded by the same uncompressed transcript cap as persistence. When the cap is reached, the GenServer appends the truncation marker required by `DM-604`, keeps broadcasting live output to current subscribers, and stops appending additional chunks to the spool or persisted transcript buffer. This satisfies replay guarantees up to the documented transcript cap and makes truncation explicit rather than silent.

`STR-202` is implemented with explicit client acknowledgements. Every rendered chunk carries `data-position`; a lightweight LiveView hook batches acknowledgements and sends the highest contiguous rendered position for each target:

```elixir
def handle_event("ack_execution_output",
                 %{"execution_id" => execution_id, "position" => position},
                 socket) do
  Stream.ack(socket.assigns.execution_group_id, execution_id, self(), position)
  {:noreply, socket}
end
```

The Stream GenServer stores the latest ack per subscriber. On disconnect, the LiveView also stores the last acknowledged position in signed session metadata / URL state for the execution view, so a new LiveView process can resume from the same position after reconnect.

### 6.2.6 PubSub broadcast

Each chunk is broadcast on `execution_stream:<execution_id>`:

```elixir
Phoenix.PubSub.broadcast(
  Vigil.PubSub,
  "execution_stream:#{execution_id}",
  {:chunk, target_id, stream, position, text}
)
```

Multiple LiveViews (same user, multiple tabs; different users viewing the same execution) all receive the same broadcast (`STR-102`). Ordering is per-target, preserved by the GenServer's serialized processing.

### 6.2.7 Completion and persistence

When the runner exits, the Stream GenServer finalizes each per-target row independently:

1. For each target, derive per-target `outcome`, `exit_status`, `duration_ms`.
2. Gzip the complete live spool (truncated to 50 MB uncompressed per `DM-604` if it exceeded the cap — see [§4.5.3](04-data-model.md#453-transcript-size-cap-and-truncation-dm-604)).
3. In **one DB transaction per group**:
   - `UPDATE executions SET outcome=$1, exit_status=$2, ended_at=$3, duration_ms=$4, streaming_state='closed', transcript=$5, transcript_meta=$6, partial_transcript=NULL WHERE id=$7` — repeated per target via `Ecto.Multi` so all per-target rows reach their terminal state atomically.
   - One `INSERT INTO journal_entries` per target (`DM-606`, `EXEC-201`).
4. Broadcast `{:ended, execution_id, outcome}` on `execution_stream:<execution_id>` for each target; broadcast `{:group_ended, execution_group_id}` on `execution_group:<group_id>` after the last target closes.
5. Set a grace timer (default 60 s) before terminating. The grace window allows late LiveView reconnections to get the final `:ended` events without refetching from DB.

```elixir
def handle_info({:runner_done, final_state}, state) do
  state = finalize(state, final_state)

  Repo.transaction(fn ->
    Enum.each(state.targets, fn {execution_id, target} ->
      Vigil.Core.Executions.finalize_row(execution_id, target, state.spool[execution_id])
      Vigil.Core.Journal.write_for_execution(execution_id, target)
    end)
  end)

  Enum.each(state.targets, fn {execution_id, target} ->
    Phoenix.PubSub.broadcast(Vigil.PubSub, "execution_stream:#{execution_id}",
                             {:ended, execution_id, target.outcome})
  end)
  Phoenix.PubSub.broadcast(Vigil.PubSub,
    "execution_group:#{state.execution_group_id}",
    {:group_ended, state.execution_group_id})

  timer = Process.send_after(self(), :grace_expired, 60_000)
  {:noreply, %{state | grace_timer: timer}}
end

def handle_info(:grace_expired, state), do: {:stop, :normal, state}
```

Per `RBAC-109` and `ADR-0005`, denied nodes do not appear in this loop at all — they were never given an `executions` row.

### 6.2.8 In-flight durability across restarts (`EXEC-106`)

A naive design loses all buffered output when the platform restarts: the Stream GenServer holds up-to-128 KB per target in memory; a `SIGTERM` without explicit handling drops it on the floor. For a deployment in the middle of a long multi-target execution, the user sees a terminal that goes silent with no recoverable transcript of the pre-restart portion.

Two mechanisms, together, ensure in-flight output survives:

**Graceful drain on SIGTERM.** The `Vigil.Core.Execution.Supervisor` traps exits and implements `terminate/2`:

```elixir
defmodule Vigil.Core.Execution.Supervisor do
  use DynamicSupervisor

  @drain_window_ms Application.compile_env(:vigil, :execution_drain_ms, 30_000)

  def terminate(reason, _state) do
    Logger.info("Draining in-flight executions, reason=#{inspect(reason)}")

    # Signal every Stream GenServer to flush to DB now
    children = DynamicSupervisor.which_children(__MODULE__)
    deadline = System.monotonic_time(:millisecond) + @drain_window_ms

    tasks = for {_, pid, _, _} <- children, is_pid(pid) do
      Task.async(fn -> Vigil.Core.Execution.Stream.drain(pid, deadline) end)
    end

    Task.await_many(tasks, @drain_window_ms + 1_000)
    :ok
  end
end
```

`Stream.drain/2` flushes buffered output to a `executions.partial_transcript` column, preserves runner state metadata, and closes cleanly. Runners that support cancellation (Bolt, Ansible via signal) are told to stop cleanly; runners that don't (SSH with a live session) leave the remote process running — we can't reach into a remote host to stop it, so we accept that caveat and document it.

**Periodic checkpointing for long executions.** For executions exceeding a configurable window (default 60 seconds of runtime), the Stream GenServer snapshots its buffer to `executions.partial_transcript` every 30 seconds via `send_after(self(), :checkpoint, 30_000)`:

```elixir
def handle_info(:checkpoint, state) do
  persist_partial_transcripts!(state)   # gzip + write, non-blocking via Task
  Process.send_after(self(), :checkpoint, 30_000)
  {:noreply, state}
end
```

The partial transcript column is cumulative: each checkpoint writes the full checkpointed spool snapshot. On completion, the final transcript overwrites the partial one.

**Reconnection after restart.** When the platform comes back up:

1. The startup routine scans `executions` for rows with `overall_status = :running`.
2. For each, it inspects whether the Stream GenServer's runner state was drain-clean (buffers flushed) or drain-aborted (runner died mid-output). Drain state is stored in `executions.metadata.drain_state`.
3. The execution is marked `:aborted_by_restart` if the runner was mid-flight and cannot be resumed. Its partial transcript is promoted to the final transcript. A journal entry records the restart-induced abort, with severity `:warning`.
4. Clients reconnecting to the execution LiveView see the full partial transcript plus the abort marker — they don't see silent loss.

`EXEC-106` is satisfied: "A partial-output transcript is REQUIRED; silent loss of output is NOT ACCEPTABLE." Users lose live stream continuity across a restart, but they do not lose the output that was produced before it.

> **Decision: Accept runner disconnection on restart; preserve buffered output.**
> A more ambitious design would attempt to re-attach to running runners after restart (SSH `screen`-style detach/attach, cloud API long-polls resuming from a cursor). That complexity is disproportionate to the value for the deployment cadence typical of Vigil installations. The pragmatic contract — "you lose real-time stream across a restart; you keep everything printed before it; you see a clear abort marker" — meets the user need and is implementable now.

## 6.3 Plugin runner contract

Plugins implementing `:execution` provide a runner module:

```elixir
defmodule Vigil.Plugin.Execution.Runner do
  @callback start(integration_id, artifact, targets, opts) :: {:ok, runner_ref} | {:error, reason}
  @callback abort(runner_ref) :: :ok
end
```

The runner is a process started by the Stream GenServer. It owns the port or HTTP long-poll against the external tool and sends messages back:

```elixir
# Messages sent to the Stream GenServer:
{:runner_chunk, target_id, :stdout | :stderr, iodata}
{:runner_target_done, target_id, %{exit_status, duration_ms}}
{:runner_done, %{overall_status, summary}}
{:runner_error, reason}
```

Runner implementations:

- **SSH** — one process per target, owning a long-lived SSH connection from the pool. Uses `:ssh_connection.exec/3`.
- **Bolt** — one `Port` per execution (Bolt handles multi-target internally); parses Bolt's JSON output stream for per-target attribution.
- **Ansible** — one `Port` per execution using a callback plugin that emits per-task-per-host structured lines, parsed by the runner.
- **AWX/Rundeck** — HTTP-based; polls for output chunks, forwards as chunks.

Runners are supervised as children of the Stream GenServer. On runner crash, the Stream GenServer marks remaining targets as "aborted due to runner failure" and terminates.

## 6.4 Concurrency controls

PRD `EXEC-301` requires three-scope concurrency: global, per-integration, per-user.

Implementation:

```elixir
defmodule Vigil.Core.Executions.ConcurrencyGate do
  def acquire(principal, integration_id, timeout_ms) do
    with :ok <- Semaphore.acquire(:global_executions, timeout_ms),
         :ok <- Semaphore.acquire({:integration, integration_id}, timeout_ms),
         :ok <- Semaphore.acquire({:user, principal.id}, timeout_ms) do
      :ok
    else
      {:error, :timeout} -> {:error, :overloaded}
    end
  end

  def release(principal, integration_id) do
    Semaphore.release({:user, principal.id})
    Semaphore.release({:integration, integration_id})
    Semaphore.release(:global_executions)
  end
end
```

`Semaphore` is a simple GenServer counting-semaphore. Limits come from:

- `settings.concurrency.global_executions` (default 200)
- `integrations.config.concurrency` (per integration, plugin default)
- `settings.concurrency.per_user_executions` (default 20)

Release is guaranteed via `try/after` in the Stream GenServer's `terminate/2`.

## 6.5 Streaming to LiveView

The `ExecutionLive` LiveView subscribes on mount. The `:id` route parameter may be either an `execution_group_id` for the group view or an `execution_id` for a single-target detail view; the loader resolves it to `{group, visible_executions}` before subscribing.

```elixir
def mount(%{"id" => id}, _session, socket) do
  {group, executions} = load_execution_view(id)

  if connected?(socket) do
    for execution <- executions do
      Phoenix.PubSub.subscribe(Vigil.PubSub, "execution_stream:#{execution.id}")
    end
  end

  {:ok, socket
    |> assign(:execution_group_id, group.id)
    |> assign(:executions, executions)
    |> stream(:chunks, [], dom_id: &dom_id_for_chunk/1)
    |> replay_from_last_ack()}
end

def handle_info({:chunk, target_id, stream_kind, position, text}, socket) do
  chunk = %{target_id: target_id, kind: stream_kind, position: position, text: text}
  {:noreply, stream_insert(socket, :chunks, chunk)}
end

def handle_info({:ended, status}, socket) do
  {:noreply, socket
    |> assign(:executions, reload_visible(socket.assigns.execution_group_id))
    |> put_flash(:info, "Execution #{status}")}
end
```

`LiveView.stream/4` handles append-only rendering efficiently — only new chunks are diffed; the DOM grows without re-rendering prior chunks. This scales to long executions.

### 6.5.1 Disconnect/reconnect

LiveView provides automatic WebSocket reconnection. On reconnect, `mount/3` runs again; the `connected?(socket)` branch re-subscribes and replays from the Stream GenServer using the last acknowledged position. No lost output (`STR-201`, `STR-202`).

For very long disconnections, the LiveView replays from the live spool while the execution is still active or from the persisted transcript after completion. If the transcript cap was reached, the replay includes the explicit truncation marker from `DM-604`.

### 6.5.2 Multi-user viewing

Each viewing user has their own LiveView process, each subscribed to the topic. PubSub fans out the same chunk to all subscribers. Ordering is preserved because PubSub delivery is FIFO per publisher.

### 6.5.3 Pause and filter

`UI-506` allows filtering output by target and stream kind. `UI-1404` allows pausing live updates. These are client-side (LiveView.JS) operations over the streamed data; the server continues to receive and buffer.

## 6.6 Abort

A user with `execution:abort` permission can abort an in-flight execution:

```elixir
def abort(execution_id, principal) do
  with :ok <- RBAC.check(principal, "execution:abort", execution_id),
       :ok <- Stream.abort(execution_id) do
    Audit.write(principal, "execution.abort", execution_id)
    :ok
  end
end
```

The Stream GenServer's `handle_call({:abort, principal}, ...)`:

1. Tells the runner to terminate upstream work where supported.
2. Marks remaining targets as aborted.
3. Finalizes normally (still writes transcripts of partial output).

`STR-1104` is satisfied.

## 6.7 Execution history and re-run

`DM-605` requires the execution list view to group rows by `execution_group_id`, showing one summary row per group. The query joins `execution_groups` with the aggregate query from [§4.5.4](04-data-model.md#454-aggregate-group-status-computed-not-stored):

```elixir
def history(principal, filters) do
  from(g in ExecutionGroup,
    as: :group,
    where: ^visibility_filter(principal),
    order_by: [desc: g.submitted_at],
    left_lateral_join: agg in subquery(group_aggregate_query()),
    on: agg.execution_group_id == g.id,
    select: %{group: g, summary: agg}
  )
  |> apply_filters(filters)
  |> Repo.paginate(...)
end
```

Expanding a group fetches its per-target rows: `from(e in Execution, where: e.execution_group_id == ^id, preload: :node)`.

Re-run (`EXEC-204`, `DM-603`, `DM-605`) operates at three scopes:

| Scope | Source | Behaviour |
|-------|--------|-----------|
| Re-run this target only | A single `executions` row | New single-target group; same artifact and parameters; target = original `node_id`. |
| Re-run the entire group | `execution_groups.intended_targets` | New group; full original target intent re-used; RBAC re-evaluated at the new submission time, so the user may again see denials. |
| Re-run failed only | `executions WHERE execution_group_id = $1 AND outcome != 'ok'` | New group; target list = the failed subset. |

The new submission goes through the full validator (`§6.2.1`) — RBAC is *not* inherited (`ADR-0005`). If permissions have changed since the original run, the new dispatch reflects the current state.

## 6.8 Transcript retrieval

After an execution row reaches terminal state, its transcript is retrievable indefinitely (`STR-301`, `STR-302`, `EXEC-203`):

```elixir
def transcript(execution_id) do
  from(e in Execution, where: e.id == ^execution_id, select: {e.transcript, e.transcript_meta})
  |> Repo.one!()
  |> decompress_transcript()
end
```

If `transcript_meta.truncated` is true, the rendered view surfaces the truncation banner from `DM-604` ("output truncated at 50 MB; full output not persisted"). Transcript rendering uses the same LiveView component as the live stream, initialized from a static list of chunks — keeping rendering consistent between live and historical views.

## 6.9 Provisioning flows

Provisioning is structurally similar to execution — a long-running operation with progress updates. The differences:

- No per-target output; one operation produces one new node.
- State transitions (pending → creating → running → ready) instead of line-by-line output.
- Result is a new node's identity, not an exit status.

Implementation uses the same pattern:

```elixir
Vigil.Core.Provisioning.Supervisor  (DynamicSupervisor)
│
└── Vigil.Core.Provisioning.Operation  (one per provisioning request)
      │
      ├── invokes plugin's provisioning API
      ├── polls upstream task log / operation status
      ├── broadcasts {:state, new_state} on "provisioning:<op_id>"
      ├── on ready: triggers inventory refresh for the new node
      └── persists outcome + writes journal entry
```

`PROV-COM-003` (new node in inventory within one refresh cycle) is satisfied by publishing `{:inventory_changed, integration_id, :partial, [new_node_id]}` once the provisioning plugin confirms the node exists. The inventory cache warmer listens for this and refreshes the affected source.

### 6.9.1 Provisioning events in the journal

`PROV-COM-001` mandates journal entries from upstream event logs, not local inference. In the fetch-on-demand journal model:

- Provisioning lifecycle events (CloudTrail, Azure Activity Log, Proxmox task log) are fetched from the source API when the user views the node's journal timeline.
- Each provisioning-capable plugin's Events capability normalizes these upstream events into the standard journal entry format at fetch time.
- The correlation ID captured at submission (`AWS-403`, `AZ-403`) allows the journal view to correlate user-initiated ops with the upstream events they produce.

This keeps journal entries authentic — they reflect what the cloud/hypervisor *actually did*, not what Vigil thought it requested. The source tool remains the authoritative record.

## 6.10 Monitoring in the journal

Monitoring data in the journal follows the same fetch-on-demand pattern:

- Monitoring state transitions are derived from the source tool's state history API at fetch time (see [section 7](07-journal-and-events.md) for the normalization logic).
- Only state *changes* appear as journal entries (`TYPE-MON-003`, `FLOW-601`); steady-state observations are filtered out during normalization.
- Current monitoring status (for the node detail page's live status display) is fetched separately via the Monitoring capability and cached briefly in ETS.

There is no background polling or webhook handling for journal population. The journal view fetches monitoring transitions on-demand like any other external event source.

## 6.11 Testing

The execution platform is a high-stakes surface. Its tests include:

- **End-to-end via Wallaby** — submit, observe live output, reconnect, verify.
- **Property-based** — concurrent submissions, random disconnects, verify no output lost and all transcripts persisted (`TEST-304`).
- **Timeout enforcement** — inject slow runner; verify wall-clock and idle timeouts terminate.
- **Concurrency limits** — submit N+1 executions; verify the N+1th queues and then fails.
- **Abort** — abort mid-stream; verify runner terminates, partial transcript preserved.

---

[← Previous: Aggregation & Caching](05-aggregation-and-caching.md) | [Next: Journal & Events →](07-journal-and-events.md)

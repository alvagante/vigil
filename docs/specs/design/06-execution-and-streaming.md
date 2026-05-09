# 6. Execution & Streaming

This section covers PRD `EXEC-*`, `STR-*`, and the Remote Execution capability contract. The execution platform is where the system's real-time demands concentrate: live output streaming at 200ms, 100 concurrent executions, reconnection without lost output, per-target attribution, and full transcript persistence.

## 6.1 Process model

Each execution is owned by one GenServer:

```
Vigil.Core.Execution.Supervisor  (DynamicSupervisor)
│
└── Vigil.Core.Execution.Stream  (one per execution_id)
      │
      ├── spawns plugin-specific runner (CLI port, API poller)
      ├── buffers output
      ├── broadcasts chunks on PubSub
      ├── persists on completion
      └── decommissions after grace period
```

The GenServer is the single source of truth during an execution. LiveView processes subscribe. The MCP server can also subscribe (for future "watch execution" tools). Audit writes happen at start and end.

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

The context:

1. **Validates** — per `FLOW-101`: targets are reachable via the integration, RBAC permits the action on each target, command passes the allowlist.
2. **Resolves targets** — expand groups / filter to a concrete node_id list.
3. **Creates the execution row** (`executions` + `execution_targets` placeholders).
4. **Starts the Stream GenServer** via `DynamicSupervisor.start_child/2`.
5. **Writes the audit entry.**
6. **Returns** `{:ok, execution_id}` to the caller.

### 6.2.2 Permission validation

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

### 6.2.3 Stream GenServer

```elixir
defmodule Vigil.Core.Execution.Stream do
  use GenServer

  # State
  defstruct [
    :execution_id,
    :integration_id,
    :plugin_module,
    :targets,              # list of %{id, node_id, identity}
    :runner_ref,            # reference to the plugin runner (port, task)
    buffer: %{},           # per-target ring buffer of recent chunks
    buffer_position: %{},  # monotonic position per target
    finished_targets: %{},
    overall_status: :running,
    grace_timer: nil
  ]

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: via(args.execution_id))

  def get_buffer(execution_id, since_position) do
    GenServer.call(via(execution_id), {:backfill, since_position})
  end

  def abort(execution_id, principal) do
    GenServer.call(via(execution_id), {:abort, principal})
  end
end
```

State lives entirely in the GenServer. LiveView disconnects don't affect it (`STR-203`).

### 6.2.4 Buffering

Per-target ring buffers hold the most recent N kilobytes (default 128KB per target). Each chunk gets a monotonic position number:

```elixir
%{1 => {pos_1, "chunk text"}, 2 => {pos_2, "chunk text"}, ...}
```

When a LiveView reconnects, it calls `get_buffer/2` with its last-received position and receives all chunks since (`STR-201`, `STR-202`). For chunks evicted from the ring buffer (long disconnections), the LiveView falls back to the persisted transcript on completion.

### 6.2.5 PubSub broadcast

Each chunk is broadcast on `execution_stream:<execution_id>`:

```elixir
Phoenix.PubSub.broadcast(
  Vigil.PubSub,
  "execution_stream:#{execution_id}",
  {:chunk, target_id, stream, position, text}
)
```

Multiple LiveViews (same user, multiple tabs; different users viewing the same execution) all receive the same broadcast (`STR-102`). Ordering is per-target, preserved by the GenServer's serialized processing.

### 6.2.6 Completion and persistence

When the runner exits:

1. The GenServer finalizes per-target exit status and duration.
2. Concatenates buffered + any overflow-to-disk chunks into the full transcript per target.
3. gzips and writes to `execution_targets.transcript`.
4. Updates `executions.ended_at` and `overall_status`.
5. Writes journal entries — one per target (`EXEC-201`, `TYPE-EXEC-003`, `DM-601`).
6. Broadcasts `{:ended, overall_status}` on the stream topic.
7. Sets a grace timer (default 60s) before terminating. The grace window allows late LiveView reconnections to get the final `:ended` event without refetching from DB.

```elixir
def handle_info({:runner_done, final_state}, state) do
  state = finalize(state, final_state)
  persist_transcripts!(state)
  write_journal_entries!(state)
  Phoenix.PubSub.broadcast(..., {:ended, state.overall_status})
  timer = Process.send_after(self(), :grace_expired, 60_000)
  {:noreply, %{state | grace_timer: timer, overall_status: final_state.overall_status}}
end

def handle_info(:grace_expired, state), do: {:stop, :normal, state}
```

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

The `ExecutionLive` LiveView subscribes on mount:

```elixir
def mount(%{"id" => execution_id}, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(Vigil.PubSub, "execution_stream:#{execution_id}")
  end

  {:ok, socket
    |> assign(:execution_id, execution_id)
    |> assign(:execution, load_execution(execution_id))
    |> stream(:chunks, [], dom_id: &dom_id_for_chunk/1)
    |> backfill_buffer()}
end

def handle_info({:chunk, target_id, stream_kind, position, text}, socket) do
  chunk = %{target_id: target_id, kind: stream_kind, position: position, text: text}
  {:noreply, stream_insert(socket, :chunks, chunk)}
end

def handle_info({:ended, status}, socket) do
  {:noreply, socket
    |> assign(:execution, reload(socket.assigns.execution_id))
    |> put_flash(:info, "Execution #{status}")}
end
```

`LiveView.stream/4` handles append-only rendering efficiently — only new chunks are diffed; the DOM grows without re-rendering prior chunks. This scales to long executions.

### 6.5.1 Disconnect/reconnect

LiveView provides automatic WebSocket reconnection. On reconnect, `mount/3` runs again; the `connected?(socket)` branch re-subscribes and re-backfills from the Stream GenServer's buffer using the last-rendered position. No lost output (`STR-201`).

For very long disconnections where the ring buffer has rolled past the last-rendered position, the LiveView detects the gap and either:
- Fetches the complete transcript from the DB (if execution ended), or
- Shows a "gap indicator" with a "reload full output" affordance.

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

Execution history queries are plain Ecto queries against `executions` and `execution_targets`:

```elixir
def history(principal, filters) do
  from(e in Execution,
    where: ^visibility_filter(principal),
    order_by: [desc: e.started_at],
    preload: [:targets]
  )
  |> apply_filters(filters)
  |> Repo.paginate(...)
end
```

Re-run (`EXEC-204`, `DM-603`) is a UI affordance that pre-fills a new execution form with the historical submission's parameters. The user can edit targets and parameters before submitting. The new execution is entirely separate from the original — same submission flow, same validation.

## 6.8 Transcript retrieval

After execution ends, transcripts are retrievable indefinitely (`STR-301`, `STR-302`, `EXEC-203`):

```elixir
def transcript(execution_target_id) do
  from(et in ExecutionTarget, where: et.id == ^execution_target_id)
  |> Repo.one!()
  |> decompress_transcript()
end
```

Transcript rendering uses the same LiveView component as the live stream, initialized from a static list of chunks. This keeps rendering consistent.

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

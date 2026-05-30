# 15. Proxmox Integration — Detailed Design

This section describes the concrete design of the Proxmox plugin. It realizes PRD section 9.2 (`PROX-101`..`PROX-807`).

The plugin is an umbrella child application: `apps/vigil_integrations_proxmox/`. It provides **Inventory**, **Facts**, and **Provisioning** capabilities. It explicitly does **not** declare Remote Execution, Configuration, Events, Monitoring, Reports, or Deployment (`PROX-301` opening note) — Proxmox is the on-premise hypervisor target for Phase 1 (design/01 §1.5), distinct from the cloud provisioning integrations (AWS / Azure, Phase 2a).

The plugin also declares three supplementary capabilities: **snapshot management**, **console access**, and **cluster resource topology**.

## 15.1 Supervision tree

```
Vigil.Integrations.Proxmox.Application
│
└── Vigil.Integrations.Proxmox.Supervisor.<integration_id>
      │
      ├── Vigil.Integrations.Proxmox.ConfigServer
      ├── Vigil.Integrations.Proxmox.Health
      ├── Vigil.Integrations.Proxmox.API.Client            # Finch-backed HTTP
      ├── Vigil.Integrations.Proxmox.TicketBroker          # VNC proxy tickets (PROX-801)
      ├── Vigil.Integrations.Proxmox.TaskPoller            # cluster task log subscription
      ├── Vigil.Integrations.Proxmox.ConcurrencyLimiter
      ├── Vigil.Integrations.Proxmox.RequestCoalescer
      └── Vigil.Integrations.Proxmox.FuseSupervisor        # :fuse breaker per sub-system
```

Each GenServer is registered via the plugin's Registry namespace:

```elixir
defp via(id, kind), do: {:via, Registry, {Vigil.Plugin.Registry, {:proxmox, id, kind}}}
```

Supervisor strategy is `:one_for_one`. The `TicketBroker` and `TaskPoller` are independent of the main API client — losing one does not require restarting the others.

## 15.2 API client

Proxmox exposes a REST API at `/api2/json/`. The client is a Finch-backed HTTP wrapper with per-integration connection pool, circuit breaker, and credential management.

```elixir
defmodule Vigil.Integrations.Proxmox.API.Client do
  use GenServer

  def list_resources(integration_id, type, opts \\ []),
    do: call(integration_id, :get, "/cluster/resources", %{type: type}, opts)

  def list_tasks(integration_id, opts),
    do: call(integration_id, :get, "/cluster/tasks", opts[:filters], opts)

  def vm_status(integration_id, node, vmid, opts),
    do: call(integration_id, :get, "/nodes/#{node}/qemu/#{vmid}/status/current", %{}, opts)

  def vm_config(integration_id, node, vmid, opts),
    do: call(integration_id, :get, "/nodes/#{node}/qemu/#{vmid}/config", %{}, opts)

  def create_vm(integration_id, node, params, opts),
    do: call(integration_id, :post, "/nodes/#{node}/qemu", params, opts)

  def vnc_proxy(integration_id, node, type, vmid, opts),
    do: call(integration_id, :post,
             "/nodes/#{node}/#{type}/#{vmid}/vncproxy", %{websocket: 1}, opts)

  # ... snapshot, lifecycle, storage discovery, etc.
end
```

### 15.2.1 Authentication (PROX-501 / PROX-502 / PROX-503)

Two modes:

| Mode | Header / parameter | Refresh |
|------|---------------------|---------|
| API token (preferred) | `Authorization: PVEAPIToken=<token_id>=<token_secret>` | Never (long-lived) |
| Ticket (username/password) | `CSRFPreventionToken` header + `PVEAuthCookie` | Re-authenticated every 110 minutes (Proxmox tickets are 2 h; refresh just before expiry) |

The `ConfigServer` materialises the auth headers once and the `API.Client` injects them on every request:

```elixir
defp auth_headers(%{auth: %{method: :token, token_id: id, token_secret: sec}}) do
  [{"Authorization", "PVEAPIToken=#{id}=#{sec}"}]
end

defp auth_headers(%{auth: %{method: :ticket}} = state) do
  ticket = TicketRefresher.current_ticket(state.integration_id)
  [{"Cookie", "PVEAuthCookie=#{ticket.cookie}"},
   {"CSRFPreventionToken", ticket.csrf}]
end
```

`token_secret` and `password` resolve through `Vigil.Core.Secrets` (design/03 §3.2.4); they are never logged. `PROX-502` TLS verification is on by default; `verify_tls: false` in config is permitted but the `Health` worker emits a persistent `:degraded`-equivalent warning that surfaces in the admin UI.

### 15.2.2 Cluster resources query

`/cluster/resources` returns the full list of all guests and nodes in one call. The plugin uses this as the primary inventory source — one HTTP request instead of N requests per cluster node (`PROX-104` server-side pagination is not directly supported by Proxmox; the plugin paginates the response in-memory after retrieval and caches it):

```elixir
def list_all_guests(integration_id) do
  case API.Client.list_resources(integration_id, "vm") do
    {:ok, %{body: items}} -> {:ok, Enum.map(items, &normalize_guest/1)}
    err -> err
  end
end
```

A `type=vm` query returns both QEMU and LXC guests; the `type` field on each item distinguishes them. The plugin emits two logical streams to the linker, one per guest type, but they share the cluster-resources fetch — one upstream call, two emit passes.

## 15.3 Capabilities

### 15.3.1 Inventory

`PROX-101`..`PROX-105`: VMs, LXC containers, and hypervisor nodes are all surfaced as inventory items. The plugin emits three classes of observation, distinguished by `metadata.proxmox_type`:

| `proxmox_type` | Source | Identity attributes |
|----------------|--------|---------------------|
| `qemu` | `/cluster/resources?type=vm` filtered by `type=qemu` | `vmid` (cluster-scoped), `name`, `hostname` if reported in config |
| `lxc` | `/cluster/resources?type=vm` filtered by `type=lxc` | `vmid` (cluster-scoped), `name`, `hostname` if reported in config |
| `pve_node` | `/cluster/resources?type=node` | hostname (cluster node FQDN) |

`PROX-105` identity confidence:

```elixir
@impl Vigil.Plugin.Inventory
def identity_confidence do
  [
    %{attribute: :hostname,   level: :best_effort},
    %{attribute: :primary_ip, level: :best_effort}
  ]
end
```

VM/LXC `vmid` is intentionally **not** declared as a linkable attribute. It is stable within a cluster but two different Proxmox clusters can have the same `vmid` for different guests — using it for cross-integration linking would produce wrong matches. The plugin instead surfaces `vmid` in `Vigil.Plugin.Node.metadata.proxmox_vmid` so the LiveView can display it without it being a linking key.

The hypervisor node entry (`proxmox_type: pve_node`) is intentionally separate from guests so the inventory view can render hypervisors distinctly (`PROX-103`) and so the `proxmox:resource_topology` supplementary capability can iterate cluster nodes without a separate query.

### 15.3.2 Facts

`PROX-201`..`PROX-203`: two-tier facts:

| Tier | Source | TTL |
|------|--------|-----|
| Configuration | `/nodes/{node}/{type}/{vmid}/config` | 5 minutes (`PROX-203`) |
| Live usage | `/nodes/{node}/{type}/{vmid}/status/current` | 30 seconds (`PROX-203`) |

The Facts capability fetches both in parallel and merges:

```elixir
@impl Vigil.Plugin.Facts
def for_node(integration_id, node_id, _opts) do
  with {:ok, %{cluster_node: cn, type: t, vmid: id}} <- locate(integration_id, node_id),
       {:ok, [config, status]} <- Task.await_many([
         Task.async(fn -> Cache.fetch_or({integration_id, :config, t, id},
                                          fn -> API.Client.config(integration_id, cn, t, id) end) end),
         Task.async(fn -> Cache.fetch_or({integration_id, :usage, t, id},
                                          fn -> API.Client.status(integration_id, cn, t, id) end) end)
       ], 10_000) do
    {:ok, merge_facts(config, status, integration_id)}
  end
end
```

The two short TTLs reflect different change rates: VM configuration changes only when an admin edits it; live usage is a sliding window of real-time data and is meaningful only for seconds. The 30-second usage TTL means a refresh-spamming user sees the most recent retrieved snapshot but does not stampede the API.

### 15.3.3 Provisioning

`PROX-301`..`PROX-308`: the Provisioning capability mounts under `Vigil.Core.Provisioning.Supervisor` (design/06 §6.9). The Proxmox runner module:

```elixir
defmodule Vigil.Integrations.Proxmox.Provisioning.Runner do
  @behaviour Vigil.Plugin.Provisioning.Runner

  @impl true
  def start(integration_id, %{action: :create_vm} = req, opts) do
    with {:ok, %{upid: upid}} <- API.Client.create_vm(integration_id,
                                                       req.cluster_node, req.params, opts) do
      {:ok, %{integration_id: integration_id, upid: upid, kind: :qemu}}
    end
  end

  @impl true
  def start(integration_id, %{action: :clone_template} = req, opts), do: ...
  def start(integration_id, %{action: :destroy_vm}    = req, opts), do: ...
  def start(integration_id, %{action: :start_vm}      = req, opts), do: ...
  # ... stop, shutdown, reboot, suspend, resume, LXC variants ...

  @impl true
  def watch(%{integration_id: id, upid: upid}) do
    Stream.unfold(:initial, fn _ ->
      case API.Client.task_status(id, upid) do
        {:ok, %{"status" => "running"} = t}   -> {{:state, :running,  t}, :continue}
        {:ok, %{"status" => "stopped", "exitstatus" => "OK"} = t} ->
          {{:ended, :ok, t}, :done}
        {:ok, %{"status" => "stopped", "exitstatus" => err}} ->
          {{:ended, {:failed, err}, %{}}, :done}
        :done -> nil
      end
      |> tap(fn _ -> Process.sleep(1_000) end)   # poll cadence
    end)
  end
end
```

`PROX-308` task progress: the `watch/1` stream produces state-transition events forwarded to the Provisioning LiveView via the standard `provisioning:<op_id>` topic. Proxmox tasks emit a `UPID` (Unique Process IDentifier) the moment the API call returns; the LiveView shows `pending → running → ok|failed` driven by the polling stream.

`PROX-305` resource discovery: `/cluster/resources?type=storage`, `/cluster/resources?type=node`, `/nodes/{node}/aplinfo`, `/nodes/{node}/storage/{storage}/content?content=images,iso,vztmpl` are all wrapped in `API.Client.discover/2`. Results are cached per integration with a 5-minute TTL — operators changing storage configuration rarely need sub-minute discovery refresh.

`PROV-COM-008` (don't destroy nodes the integration didn't create): the plugin tracks "managed by this integration" via the `node_sources` row attributing the node to this integration. Destroy operations check that the target's `node_sources` includes this integration before invoking the API; if the user attempts to destroy a guest the integration only *sees* but did not create or claim, the destroy is rejected with a clear message.

### 15.3.4 Snapshot management

PRD `PROX-701`..`PROX-707` — snapshots are a first-class Proxmox concept exposed as a `node_tab` supplementary capability.

#### Tree retrieval (PROX-701 / PROX-702)

```elixir
def snapshot_tree(integration_id, node, type, vmid) do
  case API.Client.list_snapshots(integration_id, node, type, vmid) do
    {:ok, items} -> {:ok, build_tree(items)}
    err -> err
  end
end

defp build_tree(items) do
  by_name = Map.new(items, &{&1["name"], normalize_snapshot(&1)})

  Enum.map(items, fn item ->
    %{
      name: item["name"],
      description: item["description"],
      created_at: parse_time(item["snaptime"]),
      vmstate?: item["vmstate"] == 1,
      parent: item["parent"]
    }
  end)
  |> link_parents(by_name)             # produce children: [...] per node
  |> roots()                            # snapshots with parent == nil or "current"
end
```

Proxmox returns snapshots as a flat list with `parent` strings; `build_tree/1` reassembles the actual tree topology. The `current` pseudo-snapshot returned by Proxmox is filtered out — it represents the live state and is not a real snapshot.

#### Mutations (PROX-703 / PROX-704 / PROX-705 / PROX-706)

Snapshot create, revert, and delete each return a UPID and are watched via the same task-polling stream as provisioning operations:

```elixir
def create_snapshot(integration_id, target, %{name: name} = params, principal) do
  with :ok <- RBAC.check(principal, snapshot_perm(:create, target), target),
       {:ok, %{upid: upid}} <- API.Client.create_snapshot(integration_id, target, params),
       :ok <- Journal.write_snapshot_event(target, :created, params, principal) do
    {:ok, upid}
  end
end
```

`PROX-704` revert confirmation: the revert action does not commit until the user confirms. The platform's `<.confirmation_modal>` (design/09 §9.8) names the snapshot and explicitly states that current guest state will be overwritten:

```heex
<.confirmation_modal
  target={@snapshot.name}
  action="revert"
  impact="Current guest state will be permanently overwritten with the snapshot"
  typed_confirmation={@snapshot.name}
  on_confirm="confirm_revert">
  <:details>
    Guest: <%= @target.name %> (<%= @target.vmid %>)
    Snapshot created: <%= relative_time(@snapshot.created_at) %>
    RAM state included: <%= @snapshot.vmstate? %>
  </:details>
</.confirmation_modal>
```

Confirmation requires the user to type the snapshot name — protecting against muscle-memory click-through on a destructive operation.

`PROX-705` delete with children: Proxmox rejects deletion of a snapshot with children. The plugin surfaces this rejection as an actionable error rather than a 500:

```elixir
defp handle_delete_error({:proxmox_api, %{status: 500, body: %{"data" => msg}}})
     when is_binary(msg) do
  cond do
    String.contains?(msg, "snapshot has child") ->
      {:error, %Plugin.Error{
        category: :user_input,
        message: "Cannot delete a snapshot that has child snapshots — delete the children first.",
        retriable?: false
      }}

    true -> {:error, %Plugin.Error{category: :persistent_external, message: msg}}
  end
end
```

`PROX-706`: each snapshot mutation generates a journal entry through `Vigil.Core.Journal.insert_node_entry/1`, attributed to the principal and carrying the upstream UPID for back-reference.

#### Hidden vs. greyed (PROX-707)

`PROX-707` requires the `snapshot_manager` tab to be hidden entirely when the user has no snapshot permissions, but to mount with reduced affordances when the user has read but not mutate. This is implemented in the supplementary-capability mount path: the tab is registered with `rbac_permission: "proxmox:vm:snapshot:read"`, so a user without read permission sees no tab at all. The tab's internal rendering then conditionally hides Create / Revert / Delete buttons based on the principal's permissions:

```heex
<.snapshot_tree tree={@tree}>
  <:row :let={snap}>
    <.button :if={can?(@principal, "proxmox:vm:snapshot:create", @target)}
             phx-click="open_snapshot_form">Create child</.button>
    <.button :if={can?(@principal, "proxmox:vm:snapshot:revert", @target)}
             phx-click="confirm_revert" phx-value-snap={snap.name}>Revert</.button>
    <.button :if={can?(@principal, "proxmox:vm:snapshot:delete", @target)}
             phx-click="confirm_delete" phx-value-snap={snap.name}>Delete</.button>
  </:row>
</.snapshot_tree>
```

This is the only place in the codebase where conditional rendering by permission *is* the right pattern (rather than hiding the entire tab) — the tab is itself the read affordance; mutations within it are layered on top.

### 15.3.5 Console access

PRD `PROX-801`..`PROX-807` — the console is a `node_action` supplementary capability that brokers Proxmox VNC proxy tickets. Vigil does **not** relay the console stream itself; the browser connects directly to the Proxmox VNC proxy.

#### Ticket broker (PROX-803)

```elixir
defmodule Vigil.Integrations.Proxmox.TicketBroker do
  use GenServer

  def issue(integration_id, target, principal) do
    GenServer.call(via(integration_id, :ticket_broker),
                   {:issue, target, principal}, 15_000)
  end

  def handle_call({:issue, target, principal}, _from, state) do
    with :ok <- RBAC.check(principal, console_perm(target), target),
         :ok <- ensure_running(state.integration_id, target),          # PROX-805
         {:ok, ticket} <- request_vnc_proxy(state.integration_id, target) do
      write_console_audit_entry(target, principal)                     # PROX-806
      {:reply, {:ok, build_console_url(state.config, target, ticket)}, state}
    end
  end
end
```

`PROX-803` tickets are never cached: each call issues a fresh `vncproxy` request to Proxmox. The ticket includes a one-time random secret with a short server-side validity window (Proxmox enforces this internally).

`PROX-805`: the broker first calls `vm_status` and rejects with a clear message if `status != "running"`. The `node_action` declaration in the supplementary registry is conditional on the same predicate — the action button does not appear in the action bar for stopped guests. The broker enforces it again at request time as a defence-in-depth backstop against stale UI state.

#### Console URL construction (PROX-802 / PROX-804)

```elixir
defp build_console_url(config, target, ticket) do
  query = URI.encode_query(%{
    "console" => target.type,                # "kvm" or "lxc"
    "novnc" => 1,                            # PROX-804: prefer noVNC
    "vmid" => target.vmid,
    "node" => target.cluster_node,
    "vncticket" => ticket.ticket
  })

  # PROX-802: opens in a new tab via target="_blank" on the link element
  "#{config.endpoint}/?#{query}"
end
```

`PROX-804`: noVNC is preferred over SPICE. The plugin only chooses SPICE when the VM's `display` config explicitly requests it and the operator has set `prefer_spice: true` — otherwise noVNC, which works in any modern browser without a plugin.

`PROX-802`: the LiveView renders the console URL as a link with `target="_blank"` and a one-shot `data-href` attribute consumed by a small JS hook. The hook opens the URL once and clears the attribute, so a re-render does not re-open the tab.

#### Audit and warning surface (PROX-806 / PROX-807)

`PROX-806`: console launch writes a high-severity audit entry with action `proxmox.console.launch`, target = the guest, params = `%{ticket_id: ticket.id, console_type: type}`. The audit row also carries a `params.notice` field flagging that console sessions bypass guest OS access controls.

`PROX-807`: the integration administration UI's RBAC editor displays a permanent banner adjacent to the `proxmox:vm:console` and `proxmox:lxc:console` permission rows:

> ⚠ Granting console access is **root-equivalent**. The console session bypasses SSH, sudo, and any OS-level access controls on the guest. Treat this permission as equivalent to giving the user direct shell access as root on every targeted guest.

The banner is non-dismissible; it always shows when these permissions are visible in the editor.

### 15.3.6 Supplementary capabilities

```elixir
@impl Vigil.Plugin
def supplementary_capabilities do
  [
    cap("proxmox:snapshot_manager", :node_tab,    "Snapshots",
        "proxmox:vm:snapshot:read", UI.SnapshotManagerTab),
    cap("proxmox:console",          :node_action, "Console",
        "proxmox:vm:console",       UI.ConsoleAction),
    cap("proxmox:resource_topology",:global_page, "Cluster topology",
        "proxmox:cluster:read",     UI.ResourceTopologyPage)
  ]
end
```

| Capability ID | Slot | Data source | RBAC |
|---------------|------|-------------|------|
| `proxmox:snapshot_manager` | `node_tab` | `snapshot_tree/4` + per-action API calls | `proxmox:vm:snapshot:read` (mount); mutation buttons gated independently |
| `proxmox:console` | `node_action` | `TicketBroker.issue/3` | `proxmox:vm:console` / `proxmox:lxc:console` (privileged — see PROX-807) |
| `proxmox:resource_topology` | `global_page` | `/cluster/resources?type=node` + per-node usage aggregation + HA status query | `proxmox:cluster:read` |

The mount predicate `plugin_linked_to_node?` (design/03 §3.10.3) ensures the snapshot tab and console action appear only on nodes attributed to this Proxmox integration. A node reported only by AWS will not see Proxmox's snapshot tab even with the integration healthy.

For LXC guests, the supplementary registry emits a second `proxmox:console` slot keyed to the `proxmox:lxc:console` permission — the same UI module, different RBAC. This is the cleanest way to honour the PRD's separate `proxmox:vm:console` and `proxmox:lxc:console` permissions (`PROX-612` / `PROX-615`) without forking the UI module.

## 15.4 Journal

`PROX-401`..`PROX-403`: journal entries come from Proxmox's cluster task log, fetched on-demand when the user opens a node's journal (design/07 §7.6). The plugin does **not** synthesize journal entries from its own observed state changes — Proxmox's task log is the authoritative record (this is the same principle `PROV-COM-001` applies to AWS/Azure).

```elixir
defmodule Vigil.Integrations.Proxmox.Events do
  @impl Vigil.Plugin.Events
  def fetch_events(config, node_identity, opts) do
    %{cluster_node: cn, vmid: vmid} = node_identity
    time_range = Keyword.fetch!(opts, :time_range)

    case API.Client.list_tasks(config.integration_id, %{
           node: cn, vmid: vmid,
           since: DateTime.to_unix(time_range.from),
           until: DateTime.to_unix(time_range.to)
         }) do
      {:ok, tasks} -> {:ok, Enum.map(tasks, &normalize_task(&1, config.integration_id))}
      err -> err
    end
  end

  defp normalize_task(task, integration_id) do
    %{
      source_event_id: task["upid"],
      occurred_at: DateTime.from_unix!(task["starttime"]),
      entry_type: classify_task_type(task["type"]),     # "qmcreate" → :provision_create, etc.
      summary: human_summary(task),
      severity: severity_from_exitstatus(task["status"], task["exitstatus"]),
      detail: %{
        upid: task["upid"],
        proxmox_user: task["user"],                     # the Proxmox account that initiated
        duration_s: (task["endtime"] || 0) - task["starttime"],
        exitstatus: task["exitstatus"]
      },
      references: %{proxmox_upid: task["upid"]}
    }
  end
end
```

`PROX-402` task type coverage: the `classify_task_type/1` table maps Proxmox's task types onto the journal's entry types — `qmcreate` / `lxc-create` → `:provision_create`, `qmdestroy` / `vzdestroy` → `:provision_destroy`, `qmstart` / `vzstart` → `:lifecycle_start`, and so on for stop, shutdown, reboot, suspend, resume, migrate, clone, snapshot.

`PROX-403`: `detail.proxmox_user` carries the Proxmox-side initiator. When the action was Vigil-initiated, the Vigil user is also recorded in the audit trail and correlated via the matching UPID (design/06 §6.2.1 correlation pattern).

## 15.5 Caching

| Capability | Default TTL | Notes |
|------------|-------------|-------|
| Inventory (`/cluster/resources`) | 1 min | One call returns the full cluster; refresh is cheap |
| Facts (config) | 5 min (`PROX-203`) | VM config rarely changes; admin-driven |
| Facts (live usage) | 30 s (`PROX-203`) | Real-time data; very short TTL |
| Resource discovery | 5 min | Storage / template / ISO lists |
| Snapshot tree | 30 s | Refresh on mutation via cache invalidation hook |
| Cluster topology | 60 s | Aggregation of per-node usage for `resource_topology` |

All caches use the shared-cache model from revised `CACHE-006` (design/05 §5.3) — keyed by integration + capability + args, not by principal. RBAC filtering is applied at presentation time.

Webhook-driven invalidation is not supported (`CACHE-004` is not satisfied here): Proxmox does not emit cluster-wide webhooks for inventory or guest-state changes. Cache freshness depends on the configured TTL plus user-triggered refresh.

## 15.6 Configuration schema

Following PRD §9.2.9:

```elixir
%Vigil.Plugin.Schema{
  fields: [
    %Field{name: "endpoint", type: :url, required: true,
           validators: [&must_be_https/1]},
    %Field{name: "auth.method", type: {:enum, [:token, :password]}, required: true},
    %Field{name: "auth.token_id", type: :string, required: false,
           conditional_on: %{"auth.method" => :token}},
    %Field{name: "auth.token_secret", type: :secret, required: false, secret?: true,
           conditional_on: %{"auth.method" => :token}},
    %Field{name: "auth.username", type: :string, required: false,
           conditional_on: %{"auth.method" => :password}},
    %Field{name: "auth.password", type: :secret, required: false, secret?: true,
           conditional_on: %{"auth.method" => :password}},
    %Field{name: "realm", type: :string, required: false, default: "pam"},
    %Field{name: "verify_tls", type: :boolean, required: false, default: true},
    %Field{name: "cluster_nodes", type: {:list, :string}, required: false},
    %Field{name: "cache_ttl.inventory", type: :duration, required: false, default: 60_000},
    %Field{name: "cache_ttl.facts_config", type: :duration, required: false, default: 300_000},
    %Field{name: "cache_ttl.facts_usage",  type: :duration, required: false, default: 30_000},
    %Field{name: "concurrency", type: :pos_integer, required: false, default: 4},
    %Field{name: "circuit_breaker.max_failures", type: :pos_integer, required: false, default: 5},
    %Field{name: "prefer_spice", type: :boolean, required: false, default: false}
  ]
}
```

The schema's "test connection" probe runs `GET /version` (authenticated) and reports the Proxmox VE version. `verify_tls: false` is permitted but always triggers a `:degraded` health state with a persistent diagnostic — operators see they are running with disabled TLS verification any time they look at the integration card.

## 15.7 RBAC permissions

PRD `PROX-601`..`PROX-616` — the plugin contributes the following permissions:

| Permission | Allows | Notes |
|------------|--------|-------|
| `proxmox:inventory:read` | List VMs, LXC containers, and hypervisor nodes | |
| `proxmox:facts:read` | View guest config and resource usage | |
| `proxmox:cluster:read` | Resource topology supplementary capability | Required for `proxmox:resource_topology` |
| `proxmox:vm:create` | Create QEMU VMs | |
| `proxmox:vm:destroy` | Destroy QEMU VMs | |
| `proxmox:vm:start` / `proxmox:vm:stop` / `proxmox:vm:reboot` / `proxmox:vm:suspend` / `proxmox:vm:resume` | Lifecycle operations on VMs | Each granted independently |
| `proxmox:vm:snapshot:read` | View VM snapshot tree | Mount predicate for `snapshot_manager` |
| `proxmox:vm:snapshot:create` | Create VM snapshots | |
| `proxmox:vm:snapshot:revert` | Revert VM to snapshot | **Kept separate from create** because revert is destructive |
| `proxmox:vm:snapshot:delete` | Delete VM snapshots | |
| `proxmox:vm:console` | Launch VM console | **Privileged** (PROX-807) — root-equivalent on the guest |
| `proxmox:lxc:*` | Same set for LXC containers | Mirrors the VM permission set |
| `proxmox:lxc:console` | Launch LXC console | **Privileged** (same warning as PROX-807) |

`PROX-616` per-storage-pool restriction: the `command_policy` field on `role_permissions` carries an allowlist of cluster nodes and storage pools the role may use for create operations. The runner consults this allowlist before invoking `create_vm` / `create_lxc`:

```elixir
defp check_storage_allowlist(principal, %{cluster_node: cn, storage: sp} = req) do
  policy = RBAC.command_policy_for(principal, "proxmox:vm:create")

  cond do
    cn not in policy.cluster_nodes_allow -> {:error, :cluster_node_denied}
    sp not in policy.storage_pools_allow -> {:error, :storage_pool_denied}
    true -> :ok
  end
end
```

The denial maps onto the same per-target denial surface as `RBAC-102` — a multi-step provisioning request that targets a denied storage pool surfaces the specific check that failed (cluster node vs. storage pool vs. RBAC scope), not just a generic permission error.

## 15.8 Performance and concurrency

The Proxmox API is single-cluster; the platform's 10,000-node target (`PERF-001`) is unlikely to be saturated by a single Proxmox integration in practice (clusters are typically tens to low hundreds of guests). The relevant limits:

- **Per-integration concurrency** (`PLUG-402`): default 4 concurrent provisioning operations. Proxmox's API serialises mutation operations on the cluster level anyway; raising concurrency above ~8 produces no throughput gain and increases the risk of HTTP timeouts.
- **Inventory refresh** (`PROX-104`): one `/cluster/resources` call per refresh cycle. Even for a 500-guest cluster the response is well under a megabyte; no streaming required (unlike Ansible — §14.2.2).
- **Task polling**: the `TaskPoller` polls `/cluster/tasks` every 5 seconds with `since=last_seen_upid` to drive the journal for currently-watched nodes. The poll is shared across all subscribers via PubSub — one polling process per integration, not per LiveView.

## 15.9 Health checks

The `Health` worker probes every 30 s (`PLUG-111`):

```elixir
defp probe(state) do
  %{
    overall: aggregate(...),
    capabilities: %{
      inventory:    probe_capability(:inventory,    &check_cluster_resources/1, state),
      facts:        probe_capability(:facts,        &check_version_endpoint/1, state),
      provisioning: probe_capability(:provisioning, &check_version_endpoint/1, state),
      console:      probe_capability(:console,      &check_version_endpoint/1, state)
    }
  }
end

defp check_cluster_resources(state) do
  case API.Client.list_resources(state.integration_id, "node", timeout: 5_000) do
    {:ok, items} -> {:healthy, "#{length(items)} cluster node(s) reachable"}
    {:error, %Plugin.Error{category: :authentication}} -> {:unhealthy, "auth failed"}
    {:error, %Plugin.Error{category: :transient_external}} -> {:degraded, "transient"}
    {:error, e} -> {:unhealthy, "cluster resources unreachable: #{e.message}"}
  end
end
```

`check_version_endpoint/1` calls `GET /version` — a single lightweight endpoint that proves auth and TLS work without exercising any specific capability. The aggregation drives the four-state model (healthy / degraded / unhealthy / flapping) per design/05 §5.6.1.

## 15.10 Acceptance criteria alignment

PRD §9.5 acceptance criteria — Proxmox-specific Phase 1 items:

| Criterion | Realized by |
|-----------|-------------|
| Inventory includes VMs, LXC, hypervisor nodes | §15.3.1 three-stream emission |
| Identity confidence declared, IP/hostname best-effort | §15.3.1 `identity_confidence/0` |
| Facts split between config (5 min) and usage (30 s) | §15.3.2 dual cache TTL |
| Provisioning: create / clone-template / destroy / lifecycle | §15.3.3 runner module |
| Resource discovery before submit | §15.3.3 `API.Client.discover/2` with 5-min cache |
| Snapshot tree, create, revert (with confirmation), delete | §15.3.4 |
| Snapshot delete handles child constraint | §15.3.4 `handle_delete_error/1` |
| Console via VNC proxy ticket, opens in new tab | §15.3.5 `TicketBroker` + URL construction |
| Console only for running guests | §15.3.5 `ensure_running/2` + slot mount predicate |
| Console audit and privileged warning | §15.3.5 audit entry + non-dismissible RBAC editor banner |
| Journal from Proxmox cluster task log | §15.4 `Events.fetch_events/3` |
| Per-action and per-storage-pool RBAC | §15.7 `command_policy` consultation |
| Token auth preferred; TLS verify default on | §15.2.1 |
| Manage-only-what-this-integration-created (PROV-COM-008) | §15.3.3 destroy predicate against `node_sources` |

---

[← Previous: Ansible Integration](14-ansible-integration.md) | [Next: Deployment & Ops →](12-deployment-and-ops.md)

> The numeric ordering 11 → 14 → 15 → 12 → 13 is intentional: plugin design docs cluster together at the end of the reading order, after the platform sections. Deployment and testing close the document.

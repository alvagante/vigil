# 9. LiveView UI Architecture

This section maps the PRD's UI requirements (`UI-*`, `STR-*`, `FLOW-*`) onto a Phoenix LiveView topology. It specifies route structure, LiveView modules, component library, state management, and the UX patterns that realize the PRD's promises about live updates, progressive rendering, and source attribution.

## 9.1 Why LiveView, specifically

Vigil's UI is a server-state UI: the data the user sees is owned by the server and changes when the server learns something. A SPA would require duplicating state, synchronizing it over WebSocket, handling stale caches, and reconciling optimistic updates. LiveView collapses all of that into "the server re-renders; the diff arrives."

For the specific UI patterns in the PRD:

| PRD requirement | LiveView capability |
|-----------------|---------------------|
| Live monitoring (`UI-1403`, `STR-401`) | `handle_info/2` on PubSub messages; automatic DOM patch |
| Streaming execution output (`UI-505`, `STR-001`) | `LiveView.stream/4` for append-only collections |
| Reconnection without lost output (`STR-201`, `UI-1402`) | Built-in reconnect + session resumption; backfill pattern |
| Deep-linkable URLs (`UI-103`, `UI-104`) | `live_patch` + `handle_params/3`; URL is the state |
| Keyboard navigation (`UI-006`, `NFR-1404`) | Phoenix.Component primitives + JS.push; focus management natively |
| Progressive rendering (`FLOW-502`, `UI-903`) | LiveView async assigns + PubSub fan-in |
| Multi-tab (`STR-1001`) | Each tab is a separate LiveView process, no cross-tab coupling; shared session for auth |
| Accessibility (`UI-007`, `NFR-1401`) | Phoenix.Component's `<.form>`, labels, aria attributes; server-rendered semantic HTML |

## 9.2 Route structure

```elixir
# lib/vigil_web/router.ex

scope "/", VigilWeb do
  pipe_through [:browser, :require_auth]

  live_session :authenticated,
    on_mount: [VigilWeb.LiveAuth, VigilWeb.LiveBreadcrumbs],
    layout: {VigilWeb.Layouts, :app} do

    live "/",                          DashboardLive
    live "/inventory",                 InventoryLive,           :index
    live "/inventory/node/:id",        NodeDetailLive,          :show
    live "/inventory/node/:id/:tab",   NodeDetailLive,          :show
    live "/groups",                    GroupsLive,              :index
    live "/groups/:id",                GroupDetailLive,         :show
    live "/journal",                   GlobalTimelineLive,      :index
    live "/executions",                ExecutionsIndexLive,     :index
    live "/executions/:id",            ExecutionLive,           :show
    live "/executions/new",            ExecutionSubmitLive,     :new
    live "/provisioning",              ProvisioningIndexLive,   :index
    live "/provisioning/:integration", ProvisioningFormLive,    :new
    live "/provisioning/op/:id",       ProvisioningOperationLive, :show
    live "/reports",                   ReportsLive,             :index
    live "/reports/:id",               ReportDetailLive,        :show
    live "/health",                    HealthDashboardLive,     :index
    live "/settings/*path",            SettingsLive,            :index
  end

  live_session :admin,
    on_mount: [VigilWeb.LiveAuth, {VigilWeb.LiveAuth, :require_admin}] do
    live "/settings/integrations",      IntegrationsLive
    live "/settings/users",             UsersLive
    live "/settings/roles",             RolesLive
    live "/settings/linking",           LinkingRulesLive
    live "/settings/audit",             AuditTrailLive
  end
end

# Unauthenticated routes (login, password reset) on a separate pipeline.
# Webhooks and API on a pipeline without session auth.
# MCP endpoint on a dedicated pipeline with token auth only.
```

Only routes the current user has access to render navigation entries (`UI-101`). The navigation component reads from `current_user` and filters by permission.

## 9.3 LiveView topology

### 9.3.1 Per-page LiveView modules

Each top-level page is a LiveView module. The LiveView:

- Owns page state (filters, cursor, selected items).
- Subscribes to relevant PubSub topics on `mount`.
- Handles user events via `handle_event`.
- Handles server-pushed updates via `handle_info`.
- Re-renders declaratively via `render/1` (HEEx template).

### 9.3.2 Shared components

Common UI primitives live in `VigilWeb.Components.*`:

| Component | Purpose |
|-----------|---------|
| `<.table>` | Paginated table with sort/filter controls |
| `<.node_card>` | Node summary card with source attribution |
| `<.source_badge>` | Integration icon + label; click for drill-in |
| `<.status_chip>` | Status indicator with consistent colors (healthy/degraded/unhealthy) |
| `<.freshness_marker>` | Shows "<t> ago" or "stale" for cached data |
| `<.streaming_terminal>` | Per-target execution output renderer |
| `<.journal_entry>` | Single entry rendering with type, severity, source |
| `<.filter_bar>` | Declarative filter controls synchronized to URL |
| `<.cursor_pagination>` | Prev/next for cursor-based paging |
| `<.empty_state>` | Standard empty-state with guidance |
| `<.error_banner>` | Inline, non-blocking error display |
| `<.confirmation_modal>` | Named-target destructive-action confirmation |

These components use `Phoenix.Component` function components. They take assigns and slots, not process state, so they're testable in isolation.

### 9.3.3 LiveComponents for encapsulated state

For stateful chunks of a page that benefit from their own lifecycle — e.g., the node detail's per-section loaders — we use `LiveComponent`. Each section loads its data independently (`UI-302`, `FLOW-002`) and re-renders without affecting others.

```elixir
defmodule VigilWeb.NodeDetailLive.FactsSection do
  use VigilWeb, :live_component

  def mount(socket) do
    {:ok, socket |> assign(loading: true, data: nil, error: nil)}
  end

  def update(%{node: node} = assigns, socket) do
    send(self(), {:load_facts, assigns.id, node.id})
    {:ok, assign(socket, assigns)}
  end

  def handle_info({:load_facts, component_id, node_id}, socket) do
    task = Task.async(fn -> Vigil.Core.Facts.for_node(node_id) end)
    {:noreply, assign(socket, task: task)}
  end
end
```

Each section's error or slowness is contained to that section's rendered HTML (`UI-305`, `ERR-001`, `ERR-004`, `FLOW-002`).

## 9.4 State management patterns

### 9.4.1 URL-as-state

Filters, pagination cursors, and selected tabs live in the URL (`UI-206`). `handle_params/3` re-derives the LiveView's assigns from the URL. `push_patch/2` updates the URL without a full re-mount.

```elixir
def handle_params(params, _uri, socket) do
  filters = parse_filters(params)
  {:noreply, socket
    |> assign(:filters, filters)
    |> load_page(filters, params["cursor"])}
end

def handle_event("apply_filter", params, socket) do
  {:noreply, push_patch(socket, to: ~p"/inventory?#{filter_to_params(params)}")}
end
```

This satisfies:
- `UI-103`, `UI-104` (deep-linkable, shareable URLs)
- `UI-206` (filters in URL)
- Browser back/forward navigation works without special handling.

### 9.4.2 Streams for large collections

`LiveView.stream/4` is the right choice for any growing or paginated collection — inventory rows, journal entries, execution chunks, log lines. It avoids re-rendering existing items and reduces memory on both server and client.

```elixir
def mount(_params, _session, socket) do
  {:ok, socket |> stream_configure(:nodes, dom_id: &"node-#{&1.id}")
               |> stream(:nodes, [], reset: true)}
end
```

### 9.4.3 Progressive rendering via multiple assigns

Sections of a node detail load in parallel. Each is a separate assign; LiveView renders what's ready and re-renders when each arrives:

```elixir
def mount(%{"id" => node_id}, _session, socket) do
  node = Nodes.get!(node_id)

  socket = socket
    |> assign(:node, node)
    |> assign(:facts, :loading)
    |> assign(:configuration, :loading)
    |> assign(:journal, :loading)
    |> assign(:reports, :loading)

  parent = self()
  start_async(:load_facts,        fn -> Facts.for_node(node_id) end)
  start_async(:load_configuration, fn -> Configuration.for_node(node_id) end)
  start_async(:load_journal,       fn -> Journal.for_node(node_id, limit: 50) end)
  start_async(:load_reports,       fn -> Reports.for_node(node_id, limit: 10) end)

  {:ok, socket}
end

def handle_async(:load_facts, {:ok, facts}, socket) do
  {:noreply, assign(socket, :facts, {:loaded, facts})}
end

def handle_async(:load_facts, {:exit, reason}, socket) do
  {:noreply, assign(socket, :facts, {:error, format_error(reason)})}
end
```

`Phoenix.LiveView.start_async/3` + `handle_async/3` (LiveView 0.20+) implements the section-independent loading without boilerplate. `FLOW-002`, `UI-302`, `UI-901`, `UI-903` are met.

### 9.4.4 Loading states

`UI-901` requires loading indicators for anything over 200ms. Three patterns:

- **Skeleton** — for initial page loads; render a placeholder of the expected shape.
- **Inline spinner** — for sections loading asynchronously.
- **Specific labels** — `UI-902` requires "loading inventory from PuppetDB" style. The dispatcher knows what it's loading; passes that to the section's assign.

## 9.5 Real-time and reconnection

### 9.5.1 Reconnect detection

LiveView emits a `phx-connected` / `phx-disconnected` CSS class on the body. We use it to show a persistent banner when disconnected:

```heex
<div class="connection-indicator hidden phx-disconnected:block">
  Connection lost — reconnecting...
</div>
```

`UI-1401` satisfied.

### 9.5.2 Rehydration on reconnect

On reconnect, `mount/3` re-runs. Subscriptions are re-established. State that came from PubSub is re-fetched from its authoritative store (GenServer buffers, DB). The user sees a smooth recovery (`UI-1402`, `STR-803`).

### 9.5.3 Live-update indicators

Sections showing live-updating data include a small "live" dot or pulse (`UI-1403`). Users can pause updates (`UI-1404`) via a toggle that unsubscribes the LiveView from the topic; resume re-subscribes and backfills via DB query.

## 9.6 Specific page designs

### 9.6.1 InventoryLive

Structure:

```
+----------------------------------------------------------+
|  Filter bar: source | group | status | fact query | text |
+----------------------------------------------------------+
|  Source attribution summary:                             |
|  Sources OK: [Puppet, Bolt, AWS]  Stale: [] Down: [Azure]|
+----------------------------------------------------------+
|  Bulk actions:  [Execute on selected]  [Clear selection] |
+----------------------------------------------------------+
|  Node | Identity | Sources | Status | Groups | Last seen |
|  ...  | ...      | ...     | ...    | ...    | ...       |
+----------------------------------------------------------+
|  <- prev page     [ cursor info ]         next page ->   |
+----------------------------------------------------------+
```

Data loading uses progressive rendering per source (5.1.1). Search is debounced 300ms (`UI-205`). Filters reflect to URL (`UI-206`).

### 9.6.2 NodeDetailLive

Tab-based layout:

```
+----------------------------------------------------------------------+
|  web-prod-01  [Puppet][Bolt][AWS]  status: running                   |
|  [ Execute ] [ Decommission ] [ Console (Proxmox) ] [ Snapshot ]     |   <- action bar
+----------------------------------------------------------------------+
|  [Facts][Configuration][Events / Journal][Run History]               |
|  [Deployments][Execute][Lifecycle]                                   |
|  [Catalog (Puppet)][Hiera lookup (Puppet)][Variable browser (Ans)]   |   <- supplementary tabs
+----------------------------------------------------------------------+
|                                                                      |
|   [tab content loads here, independently]                            |
|                                                                      |
+----------------------------------------------------------------------+
```

#### Tab ordering (UI-309)

`UI-309` mandates a canonical ordering. Generic capability tabs come first in this fixed order, then supplementary `node_tab` slots in plugin load order:

| # | Tab | Source | Mounted when |
|---|-----|--------|--------------|
| 1 | Facts | Generic (Facts capability) | Any Facts-capable integration is linked to this node |
| 2 | Configuration | Generic (Configuration capability) | Any Configuration-capable integration is linked |
| 3 | Events / Journal | Generic (Events capability + Vigil-originated entries) | Always — Vigil-originated entries (executions, manual notes) ensure this tab is never empty |
| 4 | Run History | Generic (Vigil-originated executions for this node) | Always |
| 5 | Deployments | Generic (Deployment capability) | Any Deployment-capable integration is linked |
| 6 | Execute | Generic (Remote Execution capability) | Any execution integration is linked *and* the user has any execute permission for this node |
| 7 | Lifecycle | Generic (Provisioning capability) | Any Provisioning-capable integration is linked |
| 8…N | Supplementary `node_tab` slots | Per [§3.10](03-plugin-framework.md#310-supplementary-capabilities-and-ui-extension-slots) | Plugin is linked to this node *and* user has the slot's RBAC permission. Listed in plugin load order. |

Each supplementary tab label combines the capability's `display_name` with its contributing integration name — e.g., `Catalog (puppet-prod)` rather than just `Catalog` — to distinguish capabilities of the same name from different integrations (`UI-309` final sentence). If a plugin contributes multiple supplementary capabilities of the same slot type, each appears as its own tab.

The tab list is built once in `mount/3` from the registry; ordering is enforced by sorting generic tabs against the canonical table and appending supplementary tabs in `SlotRegistry.for_slot(:node_tab, ...)` return order:

```elixir
defp build_tabs(node, principal) do
  generic = canonical_generic_tabs(node, principal)         # ordered per UI-309 table above
  supplementary = Vigil.Plugin.SlotRegistry.for_slot(:node_tab,
                                                       %{node_id: node.id, principal: principal})
                  |> Enum.map(&supplementary_tab/1)
  generic ++ supplementary
end
```

Each tab is a LiveComponent loaded on demand (`handle_params` reads `:tab`, swaps the active component). Deep linking to tabs works via URL patterns like `/inventory/node/<id>/configuration` or `/inventory/node/<id>/puppet:catalog_view` (`UI-306`); supplementary tabs use their namespaced capability ID in the URL.

#### Node action bar (UI-310)

The action bar is rendered *independently of the Execute tab* (`UI-310`). A node from an inventory-only integration (Proxmox node with a `console` action; AWS node with a tag-edit action) presents `node_action` buttons even when no execute integration is linked and the Execute tab is therefore absent.

The action bar's contents are:

| Action | Source | Visible when |
|--------|--------|--------------|
| Execute | Generic (any execution integration) | At least one execute integration is linked *and* user has any execute permission |
| Decommission | Built-in (DM-1106) | User has admin role and node is `active` or `unreported` |
| Supplementary `node_action` entries | Per [§3.10](03-plugin-framework.md#310-supplementary-capabilities-and-ui-extension-slots) | Plugin linked to this node *and* user has the slot's RBAC permission |

`UI-310` explicitly: a Proxmox-only node with a `proxmox:console` `node_action` declaration is a valid and complete state — the action bar shows the Console button with no Execute tab present. `node_action` mounting goes through `SlotRegistry.for_slot(:node_action, ...)` (see [§9.6.6.3](#96633-node_action-slots-in-the-action-bar)), which has no dependency on execute-capability presence.

### 9.6.3 GlobalTimelineLive

Timeline of journal entries, fetched on-demand from source APIs. Supports:

- Type filter, severity filter, source filter, time-range picker.
- Full-text search box (client-side filtering of loaded entries).
- Auto-refresh toggle (off by default per `JRN-205`); when enabled, periodic re-fetches from upstream APIs with selectable interval and visible notice (`JRN-206`).
- Vigil-originated entries (executions, manual notes) appear immediately via PubSub without requiring the toggle.
- Click entry to expand (show detail payload, back-references).
- Click back-reference to navigate to report/execution.

### 9.6.4 ExecutionLive

Three modes driven by `:live_action`:

- `:new` — the submission form.
- `:show` — viewing a live or completed execution with streaming output.
- `:re_run` — `:new` form pre-filled from a historical execution.

The submission form's target-selection UX:

```
[ Single node search ] [ Select from inventory filter ] [ Paste list ]
```

Dynamic parameter form:

- For Bolt tasks / Ansible playbooks: fields rendered from the integration's discovery output (`UI-503`, `BOLT-203`).
- For ad-hoc commands: plain text input.

Before submission (`UI-504`):

```
You're about to run `<command>` on 23 targets.
Integration: Bolt (bolt-prod)
Targets pass RBAC: ✓     Command on allowlist: ✓
[ Submit ]  [ Cancel ]
```

During execution (`UI-505`, `UI-506`):

```
Target: web-prod-01  [running]  |  stdout only  [toggle]
  Line 1 from web-prod-01
  Line 2 from web-prod-01
  ...

Target: web-prod-02  [completed: 0]
  ...

Filter by target: [dropdown with multi-select]
[ Pause updates ]  [ Abort execution ]
```

### 9.6.5 HealthDashboardLive

Per `UI-701` and `UI-703`, each enabled integration renders as a card with a four-state headline indicator (`healthy / degraded / unhealthy / flapping` per `HEALTH-104/105`), an expandable detail panel, and a flap indicator when flapping is active.

Collapsed (default) state:

```
+--------------------------------------------------------+
|  Puppet  (puppet-prod) — puppet plugin                 |
|  ── flapping ── 4 transitions in last 30 min ──  [▾]   |
+--------------------------------------------------------+
```

The headline colour and chip text track the aggregate status from the per-integration `Health` GenServer (see design/05 §5.6.1). When `flapping?` is true, the card *also* shows the transition count from the rolling window — this is the `UI-703` requirement: flapping is visually distinct from unhealthy and the count of state changes is shown explicitly, not just a boolean flag.

Expanded state (`UI-701(c)`):

```
+----------------------------------------------------------------+
|  Puppet  (puppet-prod) — puppet plugin                         |
|  ── flapping ── 4 transitions in last 30 min ──   [▴]          |
|  ──────────────────────────────────────────────────────────    |
|  Capability       Status     Last success     Last failure    |
|  ────────────────────────────────────────────────────────     |
|  Inventory        healthy    10s ago          —                |
|  Facts            healthy    10s ago          —                |
|  Configuration    healthy    35s ago          —                |
|  Events           degraded   2m ago           1m ago: "PDB slow"|
|  Reports          healthy    1m ago           —                |
|                                                                |
|  [ Force health check ] [ Flush caches ]                       |
|  [ Reload config ]      [ Disable ]                            |
+----------------------------------------------------------------+
```

Each capability row shows the last-success timestamp, the last-failure timestamp, and the last diagnostic message — all four sub-points of `UI-701(c)` in one row. The action footer satisfies `HEALTH-103` / `UI-702`.

Headline rendering logic in HEEx:

```heex
<.card>
  <:header>
    <span class="integration-name"><%= @integration.name %></span>
    <span class="plugin-id">(<%= @integration.plugin_id %>)</span>
    <.health_chip status={@health.current} />
    <%= if @health.current == :flapping do %>
      <span class="flap-indicator" data-testid="flap-count">
        <%= @health.flap_count %> transitions in last
        <%= format_window(@health.window_ms) %>
      </span>
    <% end %>
  </:header>

  <:body :if={@expanded?}>
    <.capability_table capabilities={@health.capabilities} />
    <.action_footer integration={@integration} />
  </:body>
</.card>
```

The `<.health_chip>` component maps statuses to colours and labels:

| Status | Chip colour | Label |
|--------|-------------|-------|
| `:healthy` | green | "healthy" |
| `:degraded` | amber | "degraded" |
| `:unhealthy` | red | "unhealthy" |
| `:flapping` | red-with-pulse | "flapping" |

Flapping uses a distinct pulse animation in addition to colour so that colour-blind users get a redundant visual cue (`NFR-1401` accessibility).

The LiveView subscribes to `integration_health:all` on mount; every published health payload from a per-integration `Health` GenServer carries `{current, capabilities, flap_count}` (design/05 §5.6.1) so the card repaints without any further query. The expanded/collapsed toggle is local LiveView state, not URL-routed, since it is per-viewer ephemeral preference.

## 9.6.6 Mounting supplementary capability slots

PRD §6.7 introduces three runtime UI extension slots — `node_tab`, `global_page`, `node_action`. The plugin framework's `Vigil.Plugin.SlotRegistry` (design/03 §3.10.3) answers "what plugins want to render here for this {principal, node}?". The LiveView layer is responsible for routing, mounting, and isolating those plugin-provided LiveComponents.

### 9.6.6.1 Dynamic routing for `global_page`

Sidebar navigation entries for `global_page` capabilities are not enumerable in the router at compile time — they depend on which plugins are loaded and which integrations are configured. The router uses a catch-all live route that dispatches to a single LiveView, which resolves the slot from the URL:

```elixir
# router.ex
live "/integration/:integration_id/page/:slot_id", IntegrationPageLive, :show
```

```elixir
defmodule VigilWeb.IntegrationPageLive do
  use VigilWeb, :live_view

  def mount(%{"integration_id" => int_id, "slot_id" => slot_id}, _session, socket) do
    principal = socket.assigns.current_user

    case Vigil.Plugin.SlotRegistry.lookup(:global_page, int_id, slot_id, principal) do
      {:ok, %SupplementaryCapability{} = cap, :available} ->
        {:ok, socket
              |> assign(:capability, cap)
              |> assign(:state, :available)}

      {:ok, cap, :unavailable} ->
        # Integration disabled or unhealthy — PLUG-904 unavailable state
        {:ok, socket |> assign(:capability, cap) |> assign(:state, :unavailable)}

      :forbidden ->
        # PLUG-806: hide entirely, not greyed out — 404 rather than render disabled
        {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  def render(%{state: :available, capability: cap} = assigns) do
    ~H"""
    <.live_component
      module={@capability.ui_module}
      id={"slot-#{@capability.id}"}
      capability={@capability}
      principal={@current_user}
    />
    """
  end

  def render(%{state: :unavailable, capability: cap} = assigns) do
    ~H"""
    <.unavailable_integration_banner capability={@capability} />
    """
  end
end
```

The sidebar component renders `global_page` entries by querying the registry directly, so the navigation list updates whenever an admin enables/disables an integration:

```heex
<aside id="sidebar">
  <%= for {integration, pages} <- Vigil.Plugin.SlotRegistry.sidebar(@current_user) do %>
    <.sidebar_section integration={integration}>
      <%= for page <- pages do %>
        <.sidebar_link
          navigate={~p"/integration/#{integration.id}/page/#{page.id}"}
          label={page.display_name}
          disabled?={page.unavailable?} />
      <% end %>
    </.sidebar_section>
  <% end %>
</aside>
```

If an integration declares no `global_page` capabilities, no sidebar section is emitted (`PLUG-902`).

### 9.6.6.2 Per-node `node_tab` slots

`NodeDetailLive` queries the registry on mount to discover which plugin-provided tabs apply to the viewed node. The query passes the node's `node_sources` so the registry filters to plugins actually linked to that node (`PLUG-805`):

```elixir
def mount(%{"id" => node_id} = params, _session, socket) do
  node          = Vigil.Core.Nodes.get!(socket.assigns.scope, node_id)
  generic_tabs  = generic_tabs_for(node)                       # Overview, Facts, etc.
  plugin_tabs   = Vigil.Plugin.SlotRegistry.for_slot(:node_tab,
                                                       %{node_id: node.id,
                                                         principal: socket.assigns.current_user})
  active_tab    = params["tab"] || "overview"

  {:ok, socket
        |> assign(:node, node)
        |> assign(:tabs, generic_tabs ++ plugin_tabs)
        |> assign(:active_tab, active_tab)}
end
```

The tab rendering layer dispatches on the active tab's origin:

```heex
<%= case @active_tab_descriptor do %>
  <% %{kind: :generic, component: c} -> %>
    <.live_component module={c} id={"tab-#{@active_tab}"} node={@node} />

  <% %{kind: :supplementary, capability: cap} -> %>
    <.live_component
      module={cap.ui_module}
      id={"tab-#{cap.id}"}
      capability={cap}
      node={@node}
      principal={@current_user}
    />
<% end %>
```

Per `PLUG-809`, a plugin tab's data-call failure is isolated to its LiveComponent — the surrounding `NodeDetailLive` and other tabs render normally.

### 9.6.6.3 `node_action` slots in the action bar

The node action bar at the top of `NodeDetailLive` mounts `node_action` capabilities the same way:

```heex
<div class="action-bar">
  <.execute_button :if={can_execute?(@current_user, @node)} />
  <.lifecycle_button :if={can_decommission?(@current_user, @node)} />
  <%= for action <- Vigil.Plugin.SlotRegistry.for_slot(:node_action,
                                                        %{node_id: @node.id,
                                                          principal: @current_user}) do %>
    <.plugin_action_button
      capability={action}
      node={@node}
      phx-click="invoke_supplementary"
      phx-value-id={action.id} />
  <% end %>
</div>
```

Clicking a plugin action sends a `phx-click` event that the LiveView dispatches to `Vigil.Plugin.Dispatcher.supplementary_call/4`. The result is rendered in a dedicated panel — the registry-declared `ui_module` is reused for the output view.

### 9.6.6.4 RBAC hides slots entirely (PLUG-806)

The `for_slot/2` registry call filters by `Vigil.Core.RBAC.permitted?(principal, capability.rbac_permission)`. Slots the user is not permitted to see are never returned to the LiveView — they are hidden, not greyed out. This is enforced at the registry level so individual LiveComponents do not have to repeat the check, and there is no rendering path that produces a disabled-looking element for an unpermitted capability.

For `global_page` slots, attempting to navigate to a forbidden URL hits the `:forbidden` branch in `IntegrationPageLive.mount/3` above and redirects, rather than rendering a "permission denied" placeholder.

## 9.7 Component patterns for source attribution

`UI-1301..1303` require source attribution on every screen.

- **Row-level (lists):** `<.source_badge>` next to each row, multiple for multi-source nodes.
- **Header-level (details):** a pills row at the top of the detail page.
- **Field-level (facts):** see [§9.7.1](#971-source-badged-facts-table-plug-503--ui-308) — facts are *not* drill-in tooltips; they are rendered as a unified table where every fact carries a visible source badge.

### 9.7.1 Source-badged facts table (PLUG-503 / UI-308)

`PLUG-503` (revised) and `UI-308` together replace the earlier "reconciled value, drill-in on hover" pattern with a flat, source-badged table where conflicts are visible without any interaction. The user no longer has to hover a cell to discover that Puppet and Ansible disagree — the table shows both rows, each with its source badge.

Row construction (server-side, in the `Vigil.Core.Facts` context):

```elixir
defmodule Vigil.Core.Facts.Row do
  @enforce_keys [:key, :value, :sources]
  defstruct key: nil,
            value: nil,                # the actual fact value (any term)
            sources: []                # [%{plugin_id, integration_id, integration_name, gathered_at}]
end

def unified_rows(scope, node_id) do
  scope
  |> aggregate_per_source(node_id)         # returns [{source, fact_key, value, gathered_at}]
  |> Enum.group_by(fn {_src, k, v, _at} -> {k, v} end)   # collapse by (key + value)
  |> Enum.map(fn {{key, value}, group} ->
    %Row{key: key, value: value, sources: Enum.map(group, &to_source/1)}
  end)
  |> Enum.sort_by(& &1.key)
end
```

The grouping key is `{fact_key, value}`, not `fact_key` alone — that is what produces the "one row per distinct value" semantics that `UI-308` requires. Two integrations reporting `os.distro = "Ubuntu 22.04"` collapse to one row with two badges; one reporting `"Ubuntu 22.04"` and the other `"Ubuntu 22.04.3 LTS"` produces two rows.

Rendering:

```heex
<.table id="facts-table" rows={@filtered_rows}>
  <:col :let={row} label="Key"><.fact_key path={row.key} /></:col>
  <:col :let={row} label="Value"><.fact_value value={row.value} /></:col>
  <:col :let={row} label="Source">
    <%= for src <- row.sources do %>
      <.source_badge integration_id={src.integration_id}
                     integration_name={src.integration_name}
                     plugin_id={src.plugin_id}
                     gathered_at={src.gathered_at} />
    <% end %>
  </:col>
</.table>
```

Per-source filter (`UI-308`, `PLUG-503` final sentence):

```heex
<.filter_bar>
  <.select
    name="source"
    options={[{"All sources", nil} | Enum.map(@integrations, &{&1.name, &1.id})]}
    value={@filter.source_id}
    phx-change="filter_source" />
</.filter_bar>
```

`handle_event("filter_source", ...)` re-derives `@filtered_rows` by retaining only rows whose `sources` list contains the selected integration. The filter is purely a presentation operation over the already-loaded universe — no re-fetch.

Conflict signalling: when the same fact key appears in two or more rows with differing values, the LiveView annotates each of those rows with a `conflict?` flag (computed once during row construction) so the rendered cell can carry a subtle visual marker without the user having to drill in. This is not required by `UI-308`, which already requires conflicts to be visible as separate rows, but it surfaces the disagreement without forcing the reader to scan keys.

> **Decision: Source attribution at the row level, not behind a tooltip.**
> The earlier design routed per-source values through a hover tooltip. That hides conflict from any user not actively probing the cell — exactly the case the PRD grilling closed off. Putting source badges on every row (and producing one row per distinct value) makes the data shape and any disagreement self-evident at a glance, which is the operational property `PLUG-503` is now optimising for.

## 9.8 Confirmation flows

`UI-1201..1204` require confirmation for destructive actions. The `<.confirmation_modal>` component takes:

- `:target` — the specific name to display.
- `:action` — the action verb.
- `:impact` — estimated impact (number of affected targets, billable status).
- `:typed_confirmation` — a string the user must type (for bulk destructive).
- `:on_confirm` — the event to emit on confirmation.

```heex
<.confirmation_modal
  target="web-prod-04"
  action="terminate"
  impact="This VM will be permanently deleted"
  on_confirm="confirm_terminate">
  <:details>
    Instance ID: i-04abc123
    Region: us-west-2
    Estimated cost impact: removes $42/month
  </:details>
</.confirmation_modal>
```

## 9.9 Empty states

`UI-1001..1003` and `ERR-801..803` mandate specific empty-state copy. We have a reusable `<.empty_state>` with variants:

- First-run (no integrations): linked setup guidance.
- Filter yields nothing: "Clear filter or adjust criteria."
- Source-driven (section empty because no relevant integration): "No inventory sources are enabled. Enable an inventory-capable integration to begin."
- Data unavailable (source is down, no cache): distinct from "no data" — says so explicitly (`UI-1003`).

## 9.10 Accessibility

`UI-007` and `NFR-1401` require WCAG 2.1 AA. Practical implementation:

- **Semantic HTML** — use `<nav>`, `<main>`, `<section>`, `<article>`, `<aside>` with proper headings.
- **Focus management** — after navigation, focus the main content area. After modal open, focus the modal. After close, return focus to trigger.
- **Keyboard shortcuts** — document and implement via `<.keybinding>` component that registers a Phoenix.LiveView.JS handler.
- **Color contrast** — Tailwind config restricts to tested color pairs; CSS variables for themes.
- **aria-live regions** — status updates (connection state, toast notifications) live in an `aria-live="polite"` region.
- **Form labels** — every `<.input>` has a visible `<.label>` tied by `for`/`id`.

Automated accessibility testing via `axe-core` runs in Wallaby tests (`TEST-103`).

## 9.11 Internationalization & time

All `<.time>` components render with explicit timezone (`UI-1501`):

```heex
<.time datetime={@entry.occurred_at} tz={@current_user.timezone || "UTC"} />
```

Relative time with absolute on hover (`UI-1502`) uses a small JS hook (under `/assets/vendor/`).

Multi-language support is architecturally ready (`UI-1503`, `NFR-1402`) via Phoenix's Gettext. Phase 1 ships English only; translations can be added without refactoring.

## 9.12 Performance notes

LiveView's patch-diff protocol is efficient but has a ceiling. For the inventory page at 10,000 nodes:

- **Always paginate.** A single page of 50 rows is fine. A single page of 10,000 rows is not.
- **`stream/4` for growing lists.** Prepending or appending without re-rendering.
- **Trim assigns when possible.** Only include what the template needs; large lists not visible should live in GenServers or be lazy-loaded.
- **`temporary_assigns` for one-shot renders** — used for rendering tables that will be replaced, so they don't accumulate in socket state.

Initial render budget at 10,000-node scale, healthy: ~1.5 seconds end-to-end (`NFR-002`):

- ~200ms for initial HTTP response.
- ~500ms for server-side data fetch (cache hit).
- ~300ms for HTML rendering.
- ~500ms for browser parse + WebSocket establish + first diff.

Measured regressions over 20% block release (`NFR-010`).

## 9.13 Testing LiveViews

Three layers:

- **Unit tests** on context functions — covered in [section 13](13-testing-strategy.md).
- **LiveView tests** via `Phoenix.LiveViewTest` — mount, send events, assert rendered HTML. Medium-granularity.
- **E2E tests** via `PhoenixTest` or `Wallaby` — real browser, full flows (`TEST-103`).

Example LiveView test:

```elixir
test "inventory filters by source", %{conn: conn, user: user} do
  seed_inventory_for(user)

  {:ok, view, _html} = live(conn |> log_in(user), ~p"/inventory")

  html = view |> element("#filter-source") |> render_change(%{source: "puppet"})

  assert html =~ "web-prod-01"
  refute html =~ "aws-only-node"
end
```

---

[← Previous: Auth & RBAC](08-auth-rbac.md) | [Next: MCP & AI →](10-mcp-and-ai.md)

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
+---------------------------------------------------------+
|  web-prod-01  [Puppet][Bolt][AWS]  status: running      |
+---------------------------------------------------------+
|  [Overview][Facts][Configuration][Journal][Reports]...  |
|  [Execute][Lifecycle][Deployments][Monitoring]          |
+---------------------------------------------------------+
|                                                         |
|   [tab content loads here, independently]              |
|                                                         |
+---------------------------------------------------------+
```

Tabs shown are derived from integration capabilities active on this node (`UI-301`, `UI-303`). Each tab is a LiveComponent loaded on demand (`handle_params` reads `:tab`, swaps the active component).

Deep linking to tabs works via URL patterns like `/inventory/node/<id>/configuration` (`UI-306`).

### 9.6.3 GlobalTimelineLive

Streaming timeline of journal entries. Supports:

- Type filter, severity filter, source filter, time-range picker.
- Full-text search box (debounced).
- "Live" toggle; when on, new entries appear at top via PubSub.
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

Shows every enabled integration's card:

```
+-------------------------------------------+
|  Puppet (puppet-prod)          [healthy]  |
|  ---------------------------------        |
|  Inventory:     healthy  (last: 10s ago) |
|  Facts:         healthy                  |
|  Configuration: healthy                  |
|  Events:        degraded — "PuppetDB slow"|
|  Reports:       healthy                  |
|                                           |
|  [Force health check] [Flush caches]      |
|  [Reload config]      [Disable]           |
+-------------------------------------------+
```

Subscribed to `integration_health:all` for live updates (`HEALTH-101`, `HEALTH-102`). History graphs use the stored probe history (`HEALTH-104`).

## 9.7 Component patterns for source attribution

`UI-1301..1303` require source attribution on every screen. The pattern:

- **Row-level (lists):** `<.source_badge>` next to each row, multiple for multi-source nodes.
- **Header-level (details):** a pills row at the top of the detail page.
- **Field-level (tables of facts):** `<:col>` with a `from` annotation; on hover, per-source values surface via `<.tooltip>`.

```heex
<td class="fact-value" phx-hover-sources>
  Ubuntu 22.04
  <.tooltip>
    Puppet: Ubuntu 22.04
    Ansible: Ubuntu 22.04.3 LTS
  </.tooltip>
</td>
```

All `source_badge` clicks open a drill-in drawer with full per-source details.

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

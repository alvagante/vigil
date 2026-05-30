# 3. Plugin Framework

This section specifies the plugin framework that realizes PRD section 6. It covers the behaviour plugins implement, how they are discovered and configured, how capability calls dispatch, how resilience is applied around them, and how the conformance test suite works.

## 3.1 The plugin behaviour

Every plugin implements `Vigil.Plugin`, an Elixir behaviour. The behaviour is small; plugins compose more substantial implementations on top of it via smaller per-capability behaviours.

```elixir
defmodule Vigil.Plugin do
  @moduledoc """
  The contract every integration plugin implements.

  A plugin is an OTP application that registers a top-level module implementing
  this behaviour. The platform discovers plugins at startup and uses them to
  build supervision trees for each configured integration instance.
  """

  @type integration_id :: String.t()
  @type config :: map()
  @type capability :: :inventory | :facts | :configuration | :events
                    | :monitoring | :reports | :execution
                    | :provisioning | :deployment

  @doc "Stable plugin identifier (e.g., \"puppet\", \"aws\"). MUST NOT change across versions."
  @callback plugin_id() :: String.t()

  @doc "Human-readable plugin name for UI display."
  @callback display_name() :: String.t()

  @doc "Plugin contract version this plugin targets."
  @callback contract_version() :: Version.t()

  @doc "List of capabilities this plugin provides."
  @callback capabilities() :: [capability()]

  @doc "Configuration schema as a Vigil.Plugin.Schema."
  @callback config_schema() :: Vigil.Plugin.Schema.t()

  @doc """
  Returns a child spec for the supervision tree for a single integration instance.
  The platform calls this to start a plugin subtree for each configured instance.
  """
  @callback child_spec({integration_id(), config()}) :: Supervisor.child_spec()

  @doc """
  Describes default TTLs, timeouts, and concurrency budgets per capability.
  """
  @callback defaults() :: %{
    cache_ttl: %{capability() => pos_integer()},
    timeouts: %{capability() => pos_integer()},
    concurrency: pos_integer()
  }

  @doc """
  Declares operational permissions the platform should show to admins on enable.
  Filesystem paths read, executables invoked, network endpoints contacted, credentials used.
  """
  @callback operational_permissions() :: [Vigil.Plugin.Permission.t()]
end
```

### 3.1.1 Per-capability behaviours

Each capability has its own behaviour that defines the call surface. A plugin that declares `:inventory` implements `Vigil.Plugin.Inventory`. This keeps the plugin module focused and makes capability-specific contract testing precise.

```elixir
defmodule Vigil.Plugin.Inventory do
  @callback list_nodes(integration_id, opts :: map()) ::
    {:ok, Vigil.Plugin.Result.t(list(Vigil.Plugin.Node.t()))} |
    {:error, Vigil.Plugin.Error.t()}

  @callback get_node(integration_id, identity_attrs :: map()) ::
    {:ok, Vigil.Plugin.Result.t(Vigil.Plugin.Node.t())} |
    {:error, Vigil.Plugin.Error.t()}

  @callback flush_cache(integration_id, scope :: :all | :inventory) ::
    :ok | {:error, Vigil.Plugin.Error.t()}

  @callback identity_confidence() :: [
    %{attribute: atom(), level: :canonical | :strong | :best_effort | :unstable}
  ]
end
```

`Vigil.Plugin.Facts`, `Vigil.Plugin.Configuration`, `Vigil.Plugin.Events`, `Vigil.Plugin.Monitoring`, `Vigil.Plugin.Reports`, `Vigil.Plugin.Execution`, `Vigil.Plugin.Provisioning`, `Vigil.Plugin.Deployment` are defined analogously. Signatures are specified in each plugin-specific design document but conform to a uniform shape: the first argument is always the integration ID; operations always return `{:ok, result} | {:error, error}`; results carry source attribution as a `Vigil.Plugin.Result` wrapper.

### 3.1.2 Result and error shape

```elixir
defmodule Vigil.Plugin.Result do
  @enforce_keys [:data, :source, :fetched_at]
  defstruct data: nil,
            source: nil,               # %Source{plugin_id: ..., integration_id: ...}
            fetched_at: nil,           # DateTime
            freshness: :live,          # :live | :cached | :stale
            partial?: false,
            continuation: nil           # opaque, for cursor paging
end

defmodule Vigil.Plugin.Error do
  @type category ::
    :configuration | :authentication | :authorization_upstream
    | :transient_external | :persistent_external
    | :internal_plugin | :user_input

  @enforce_keys [:category, :message]
  defstruct category: :transient_external,
            message: "",
            detail: %{},
            retriable?: false,
            upstream_fault?: false,
            correlation_id: nil        # for log lookup (ERR-504)
end
```

Plugins return structured errors. The dispatcher (section 3.3) maps them to circuit breaker transitions, UI messages, and log classifications per PRD `ERR-401`, `ERR-402`, `ERR-403`.

### 3.1.3 Node, fact, event, and config shapes

The plugin types live in `Vigil.Plugin` because they are the contract surface:

```elixir
defmodule Vigil.Plugin.Node do
  @enforce_keys [:identity, :status, :source]
  defstruct identity: %{},            # %{certname: _, fqdn: _, hostname: _, primary_ip: _}
            status: :unknown,          # :active | :deactivated | :unreachable | :unknown
            groups: [],
            source: nil,               # %Source{}
            metadata: %{}              # plugin-specific extras
end
```

These types are translated at the boundary into Ecto schemas / DB rows by `Vigil.Core`. Plugins never see Ecto.

## 3.2 Plugin discovery and configuration

### 3.2.1 Discovery

On boot, `Vigil.Plugin.Registry` enumerates loaded OTP applications and finds those that declare `:vigil_plugin` in their `application.env`:

```elixir
# In apps/vigil_integrations_puppet/mix.exs:
def application do
  [
    mod: {Vigil.Integrations.Puppet.Application, []},
    extra_applications: [:logger],
    env: [
      vigil_plugin: Vigil.Integrations.Puppet   # the module implementing Vigil.Plugin
    ]
  ]
end
```

The registry reads this env key, verifies the module implements `Vigil.Plugin`, validates the declared `contract_version` against the platform's supported range (`PLUG-305`), and indexes the plugin under its `plugin_id`.

Community plugins distribute via Hex packages or Git dependencies — the mechanism is identical. A community plugin declares `vigil_plugin` in its `application/0` and it's picked up like any other (`PLUG-303`, `PLUG-307`).

### 3.2.2 Integration instances

Plugin discovery finds *plugin types*. `Vigil.Core.IntegrationConfig` loads *integration instances* from the database:

```sql
CREATE TABLE integrations (
  id              UUID PRIMARY KEY,
  plugin_id       TEXT NOT NULL,
  name            TEXT NOT NULL,       -- unique slug; shown in UI
  config          JSONB NOT NULL,      -- validated per plugin config_schema
  enabled         BOOLEAN NOT NULL DEFAULT true,
  contract_version TEXT NOT NULL,      -- version the config was written for
  created_at      TIMESTAMPTZ NOT NULL,
  updated_at      TIMESTAMPTZ NOT NULL
);
```

At startup, each enabled row is translated into a `start_child` call on `Vigil.Integrations.Supervisor`, which calls the plugin module's `child_spec/1` with `{integration_id, config}`. Multiple rows with the same `plugin_id` produce multiple supervised subtrees (`DM-103`).

### 3.2.3 Configuration schema and validation

`Vigil.Plugin.Schema` is a small declarative DSL for config schemas — not a new library, just a struct:

```elixir
defmodule Vigil.Plugin.Schema do
  defstruct fields: []

  defmodule Field do
    defstruct [:name, :type, :required, :default, :secret?,
               :validators, :description, :conditional_on]
  end
end
```

Plugins produce their schema in `config_schema/0`:

```elixir
def config_schema do
  %Vigil.Plugin.Schema{
    fields: [
      %Field{name: "puppetdb.url", type: :url, required: true, description: "Base URL of PuppetDB"},
      %Field{name: "puppetdb.client_cert", type: :path_or_secret_ref, required: true, secret?: true, ...},
      ...
    ]
  }
end
```

`Vigil.Plugin.Schema.validate/2` checks a config map against the schema and returns `{:ok, normalized} | {:error, [field_error]}`. Field errors carry a path, the violated rule, and a remediation hint (`PLUG-203`). The settings LiveView renders fields from the schema directly, with validation feedback inline (`UI-802`).

### 3.2.4 Secrets handling

Secrets are not stored in the `config` JSONB column as plain text. The schema marks fields as `secret?: true`; their values are stored via `Vigil.Core.Secrets`, which abstracts:

- **Native mode:** symmetric encryption using a key loaded at boot from env (`VIGIL_SECRETS_KEY`), stored in a separate `integration_secrets` table. AES-256-GCM via `:crypto`.
- **External mode (future):** pluggable backend — HashiCorp Vault, AWS Secrets Manager, Azure Key Vault. The `Vigil.Core.Secrets` behaviour allows swap-in.

The `config` JSONB stores a reference (`{"__secret_ref__": "<uuid>"}`) in place of the raw value. When the plugin's `ConfigServer` starts, it resolves refs transparently.

`NFR-201` (credentials encrypted at rest, redacted in logs and UI) is satisfied:
- Encrypted at rest by the secrets table.
- Logger filter redacts any structure containing `__secret_ref__` or values at declared secret paths.
- UI renders secret fields as `[redacted — click to replace]` (`UI-804`).

## 3.3 Dispatcher and resilience wrapping

Plugins are never called directly. All capability calls go through `Vigil.Plugin.Dispatcher`, which applies cross-cutting concerns in a consistent order:

```
Vigil.Plugin.Dispatcher.call(integration_id, :inventory, :list_nodes, args)
│
├── Resolve integration → plugin module + supervisor pid  (Registry lookup)
├── RBAC check (skip for internal callers that already checked)
├── Telemetry span :start
├── Concurrency limiter check-out (wait or :overloaded)
├── Circuit breaker check (fail fast if open)
├── Request coalescing (dedupe concurrent identical calls)
├── Cache lookup (if the call is cacheable)
│   └── hit → return cached Result, telemetry :cache_hit
├── Task.Supervisor.async with deadline
│   └── Plugin.InventoryImpl.list_nodes/2
├── On :ok  → cache if cacheable, Telemetry span :stop
├── On :err → circuit breaker transition, Telemetry span :exception
└── Return {:ok, result} | {:error, structured_error}
```

### 3.3.1 RBAC check

The dispatcher's first pass is a permission check. Callers pass a `%Vigil.Core.Principal{}` (or `:system` for internal calls) along with the call. The permission name is derived from `{plugin_id, capability, action}` — e.g., `puppet:inventory:read`, `bolt:command:execute`. See [section 8](08-auth-rbac.md) for details.

RBAC runs *before* any upstream invocation so denied actions don't hit rate-limited APIs (`EXEC-004`, `PUP-1310`).

### 3.3.2 Concurrency limiter

The per-integration `ConcurrencyLimiter` GenServer tracks the number of in-flight calls. Callers do `ConcurrencyLimiter.checkout(integration_id, timeout: 5_000)`. If the limit is at max, the call queues; on queue timeout, returns `{:error, :overloaded}`.

The caller *also* contends for the global and per-user limiters (`EXEC-301`). The three are checked in order: user → integration → global, first-come-first-served.

### 3.3.3 Circuit breaker

`:fuse` or a custom GenServer tracks consecutive failures per `{integration_id, capability}`. Configuration defaults match `RES-002` (5 consecutive failures, 30s cooldown) and are overridable per integration.

A transient error increments the failure counter. A successful call resets it. When the counter crosses the threshold, the breaker opens; further calls fail fast with `{:error, %Error{category: :transient_external, retriable?: true, message: "circuit breaker open"}}`. After cooldown, a single probe call is allowed; success closes the breaker, failure extends the cooldown (`RES-004`).

Configuration errors and authentication failures do not trip the breaker — they're persistent, not transient, and should surface as plugin health issues for admin action rather than automatic retry.

### 3.3.4 Request coalescing

Identical concurrent requests for the same data collapse to one upstream call. Implementation: a `Vigil.Plugin.Coalescer` keyed by `{integration_id, capability, args_hash}` holds a `Task` reference; callers arriving while a Task is in flight await the same Task. Result or error is fan-out-delivered to all waiters.

`PERF-004`, `PUP-1004` are served here. This is a significant win on the inventory page and on MCP-driven workloads where AI agents may issue many identical queries in parallel.

### 3.3.5 Caching

The dispatcher consults `Vigil.Core.Cache` (ETS-backed) for cacheable calls. Per the revised `CACHE-006`, cache entries hold **full, unfiltered integration responses** keyed by integration + capability + call arguments — *not* by principal. The dispatcher returns the unfiltered cache entry to its caller; RBAC target-scope filtering happens in the application layer at presentation time (see design/05 §5.3.2):

```elixir
key = {integration_id, capability, op, hash_of(args)}
```

Users with different permission scopes hit the same ETS entry, so the cache hit rate is per-integration, not per-principal. The dispatcher *does* still call the RBAC pre-flight at §3.3.1 to gate whether the principal may invoke this capability *at all* on this integration — that is a yes/no decision, separate from the per-target visibility filtering that the application layer applies after the cache lookup.

TTLs come from plugin defaults, overridable per integration per capability (`CACHE-001`, `CACHE-002`). On cache miss, the fetched result is stored with a computed expires-at. On read, if the source is currently unhealthy (checked via the PubSub health cache), stale entries are returned with `freshness: :stale` (`CACHE-005`).

Write-side calls (`EXEC-007`: execution, provisioning) are not cached (`CACHE-007`). They go directly to the plugin.

Cache flush (`PLUG-013`) is a dispatcher method `Vigil.Plugin.Dispatcher.flush(integration_id, scope)` that does an `:ets.select_delete/2` over the integration's keys and publishes `{:cache_invalidated, integration_id, scope}` on PubSub.

### 3.3.6 Deadline propagation

Every HTTP request in Vigil carries a deadline. When an LiveView mounts, it sets a deadline for inventory aggregation (default 5 seconds per `NFR-003`). The dispatcher propagates the remaining budget to the plugin via the options map:

```elixir
Dispatcher.call(id, :inventory, :list_nodes, %{deadline_ms: 4_200})
```

The plugin passes this to `Finch.request/3` as a timeout. Slow sources yield `{:error, :timeout}` without blocking the rest of the aggregation.

## 3.4 Plugin supervisor pattern

Every plugin's `child_spec/1` returns a supervisor spec. The recommended skeleton is provided as `Vigil.Plugin.SupervisorTemplate`:

```elixir
defmodule Vigil.Integrations.Puppet.Supervisor do
  use Supervisor
  alias Vigil.Integrations.Puppet

  def child_spec({integration_id, config}) do
    %{
      id: {:plugin_supervisor, integration_id},
      start: {__MODULE__, :start_link, [{integration_id, config}]},
      type: :supervisor,
      restart: :permanent
    }
  end

  def start_link({integration_id, config}) do
    Supervisor.start_link(__MODULE__, {integration_id, config},
                         name: via(integration_id))
  end

  @impl Supervisor
  def init({integration_id, config}) do
    children = [
      {Puppet.ConfigServer, {integration_id, config}},
      {Puppet.Health, integration_id},
      {Puppet.PuppetDB.Client, integration_id},
      {Puppet.Puppetserver.Client, integration_id},
      {Puppet.Hiera.Reader, integration_id},
      {Puppet.ConcurrencyLimiter, {integration_id, config["concurrency"] || 10}}
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp via(id), do: {:via, Registry, {Vigil.Plugin.Registry,
                                      {:integration_supervisor, id}}}
end
```

Plugin-specific subtrees are covered in their own design documents.

## 3.5 Plugin resource budgets

`PLUG-402` requires per-plugin memory, connection pool size, and concurrent-call budgets.

| Budget | Mechanism |
|--------|-----------|
| Memory | Per-integration ETS table with a max size; Janitor evicts LRU on pressure |
| Connection pool | Per-integration Finch pool sized from config |
| Concurrent calls | `ConcurrencyLimiter` per integration |
| Background work | Oban per-queue concurrency; one queue per integration |
| Log volume | Logger backend with per-integration rate limit (`ERR-505`, `NFR-1005`) |

Budget exhaustion returns `{:error, :overloaded}` to callers with `retriable?: true`, surfaced as "integration is under heavy load, try again" in the UI.

## 3.6 Plugin lifecycle hooks

`PLUG-101` through `PLUG-133` specify initialize, health check, data calls, and shutdown hooks. They map naturally onto OTP:

| PRD hook | Elixir mechanism |
|----------|------------------|
| `initialize` | The plugin's top supervisor `init/1` + each GenServer's `init/1`. A plugin declares its initialization success via the first `Health` probe. |
| `health_check` | `Vigil.Plugin.Health` behaviour + periodic probe worker (GenServer with `:timer.send_interval`). Defaults 30s (`PLUG-111`). |
| Data/action calls | Per-capability callbacks invoked via the dispatcher. `Task.Supervisor.async` enforces deadlines (`PLUG-122`). |
| `shutdown` | Supervisor stops each child; GenServers implement `terminate/2` to close connections and terminate in-flight work. The supervisor's `shutdown` timeout bounds the total duration (`PLUG-133`). |

## 3.7 Contract conformance suite

`PLUG-701` through `PLUG-704` require a test suite that validates plugin implementation.

```
apps/vigil_plugin/
├── lib/
│   └── vigil/plugin/
│       ├── conformance.ex                 # runs the suite
│       └── conformance/
│           ├── inventory_contract.ex      # capability-specific asserts
│           ├── facts_contract.ex
│           ├── execution_contract.ex
│           ├── provisioning_contract.ex
│           └── lifecycle_contract.ex
└── test/
    └── reference_plugin/                  # no-op plugin for platform-side testing
```

`Vigil.Plugin.Conformance.run/2` takes a `{plugin_module, test_config}` pair and:

1. Starts the plugin's subtree with the test config.
2. For each declared capability, runs the capability contract (shape of responses, timeout respect, error shape, RBAC invocation).
3. Runs lifecycle tests (init, health, reload, shutdown).
4. Returns a structured report of passes, failures, and warnings.

Two modes:

- **Full** — runs in CI against real (containerized) upstream; invokes real side effects into synthetic targets.
- **Validation (PLUG-704)** — runs at platform startup against every loaded plugin, using a read-only subset that exercises lifecycle hooks and introspection calls but does not perform writes. Failures at startup mark the plugin as suspect and are surfaced to administrators.

The **reference no-op plugin** (`PLUG-702`) sits under `apps/vigil_plugin/test/reference_plugin/`. It declares all nine capabilities, does nothing, and is used as a smoke test for the platform contract itself.

## 3.8 Plugin isolation guarantees

PRD `PLUG-401` through `PLUG-406` mandate isolation. Elixir/OTP provides more than we need at the process boundary; the remaining work is enforcement of behavioural guarantees:

- **No shared mutable state.** Each integration's state is in its own GenServers; no process accesses another integration's ETS tables directly.
- **No plugin-to-plugin coordination (`PLUG-009`).** Plugins call only `Vigil.Plugin.*` and their own internals. Crossing to another plugin must go through `Vigil.Core` (which itself goes through `Vigil.Plugin.Dispatcher`, with full RBAC).
- **No privileged access by first-party plugins (`PLUG-307`).** First-party plugin code paths pass through the same dispatcher, same RBAC, same budget checks as community plugins. No first-party bypass.
- **No `Process.whereis` or direct PID resolution across plugins.** Plugins route through the Registry. This makes it easy to audit and to test with fakes.

## 3.9 Plugin trust model — explicit statement

PRD `PLUG-407`, `PLUG-408`, `PLUG-409` require an explicit statement of what isolation the platform does and does not provide. This section is that statement.

> **Decision: Plugins are trusted at the same level as platform code.**
> In-process plugin execution is an explicit engineering choice (`PLUG-405`) made for performance. It trades data isolation for operational simplicity. The platform provides **fault isolation** (supervision), **resource isolation** (per-plugin budgets), and **API isolation** (the plugin contract) — but it does **not** provide data isolation. An installed plugin runs in the same BEAM memory space as `Vigil.Core` and can, absent additional controls,:
>
> - Read any named ETS table via `:ets.tab2list/1`
> - Subscribe to any `Phoenix.PubSub` topic including internal health events
> - Call `Vigil.Core.Secrets` module functions if it knows the name
> - Inspect any GenServer state via `:sys.get_state/1`
> - Call private-by-convention module functions via `apply/3`
>
> For first-party plugins (Puppet, Bolt, Ansible, SSH, Proxmox, AWS, Azure), which the core team maintains and reviews, this is acceptable. For community plugins, the installation decision is a security decision equivalent to installing untrusted code on the host system. Operators **MUST** vet community plugins as they would any other system-level dependency.

### 3.9.1 What the platform can and does enforce

Even within the in-process model, the platform enforces what it reasonably can:

| Defence | Mechanism | What it prevents |
|---------|-----------|-----------------|
| Named ETS tables with `:protected` access mode | Cache tables owned by `Vigil.Core.Cache` are created with `access: :protected`. Reads require the owner's permission. | Casual reads from plugin processes |
| Scoped PubSub topic prefixes | Plugins subscribe to their own `integration:<id>:*` topics. Subscribing to `rbac:*` or `audit:*` topics yields no messages because publishers scope explicitly. | Passive snooping of internal events |
| Hidden registry keys | Internal GenServers are registered under `{:internal, ...}` keys. The plugin API exposes only plugin-relevant entries. | Direct PID resolution of internal services |
| Module boundary conformance test | The conformance suite statically scans plugin code for calls to `Vigil.Core.*` internals (not `Vigil.Plugin.*`) and flags them as contract violations. | Shortcut coupling at build time, before deploy |
| Logger filter for secret metadata | Log entries from plugin modules are passed through a filter that redacts known-secret keys. | Accidental secret leakage into logs from a careless plugin |

These are **defences in depth**, not a trust boundary. A malicious or compromised plugin that attempted to bypass them (directly calling `:ets.tab2list/1` with the raw atom, subscribing to a discovered topic name, using `:sys.get_state/1`) would succeed. The platform does not claim otherwise.

### 3.9.2 What we do not do

We do not:

- Run plugins in separate OS processes (would require IPC, serialization overhead, defeats the performance rationale for in-process)
- Run plugins in sandboxed BEAM nodes with restricted module sets (BEAM does not offer this primitive)
- Ship a "trusted plugin" vs. "untrusted plugin" mode (would create a two-tier contract that the PRD explicitly forbids — `PLUG-307`, `NFR-705`)

### 3.9.3 Path to stronger isolation

If untrusted plugins ever enter scope — which would be a deliberate scope amendment — two escalation paths remain available without redesigning the plugin contract:

1. **Per-plugin OS process.** Plugin runs as a separate BEAM node connected via Distributed Erlang, or as a non-BEAM subprocess invoked via Port with a message-protocol shim. The existing `Vigil.Plugin.Dispatcher` becomes the RPC boundary. This was explicitly preserved by `PLUG-405` ("process-level isolation is not required for the initial release but MUST NOT be precluded by the contract design").
2. **Capability-based access control within the BEAM.** Adopt per-process capabilities for ETS / PubSub access using the BEAM's `access` mode flags and registry permissions, plus a runtime policy enforcer that intercepts module calls. More invasive; less proven in production Elixir.

Neither is committed work. The statement here is that the contract, not the runtime implementation, is what community plugins target — so either escalation is available later without breaking the ecosystem.

### 3.9.4 Operator-facing documentation

The plugin installation UI and operator documentation **MUST** state the trust model plainly:

> Vigil plugins run in the same process as the platform. Installing a plugin is a security decision equivalent to installing any other application dependency. Vet community plugins as you would any other system-level software.

This is the honest version of the trust model. It is also the minimum that lets operators make an informed decision.

## 3.10 Supplementary capabilities and UI extension slots

PRD §6.7 (`PLUG-801`..`PLUG-811`, `PLUG-901`..`PLUG-904`) introduces three runtime UI extension slots that any plugin — first-party or community — may declare. The platform mounts the plugin's declared UI module into the slot at request time, gated by RBAC and by whether the plugin is linked to the node being viewed.

### 3.10.1 Slot types

| Slot | Renders at | Mount predicate |
|------|------------|----------------|
| `node_tab` | A tab appended to the node detail page after the generic tabs | Plugin is linked to this node *and* the user has the slot's RBAC permission |
| `global_page` | A sidebar entry under the integration's nav section, with its own URL | Integration is enabled (renders an unavailable state if unhealthy per `PLUG-904`) *and* the user has the slot's RBAC permission |
| `node_action` | A button/menu item in the node action bar | Plugin is linked to this node *and* the user has the slot's RBAC permission |

`PLUG-806` mandates: when permission is absent, the slot is **hidden entirely** — never greyed out, never rendered as a disabled placeholder.

### 3.10.2 Manifest declaration

Supplementary capabilities are declared by adding a `supplementary_capabilities/0` callback to the plugin behaviour. The platform discovers these at the same startup pass as generic capability declarations.

```elixir
defmodule Vigil.Plugin do
  # ... existing callbacks ...

  @callback supplementary_capabilities() :: [Vigil.Plugin.SupplementaryCapability.t()]
  @optional_callbacks supplementary_capabilities: 0
end

defmodule Vigil.Plugin.SupplementaryCapability do
  @enforce_keys [:id, :slot, :display_name, :rbac_permission, :ui_module]
  defstruct id: nil,                  # namespaced: "puppet:catalog_diff" (PLUG-808)
            slot: nil,                # :node_tab | :global_page | :node_action
            display_name: nil,
            description: nil,
            rbac_permission: nil,     # e.g., "puppet:catalog_diff:view"
            data_contract: nil,       # Vigil.Plugin.Schema describing data shape
            params_schema: nil,       # Vigil.Plugin.Schema describing accepted params
            ui_module: nil,           # module implementing Phoenix.LiveComponent
            cache_ttl_ms: nil,        # per-capability cache TTL (PLUG-809)
            timeout_ms: nil           # per-capability call timeout (PLUG-809)
end
```

A Puppet plugin example:

```elixir
def supplementary_capabilities do
  [
    %SupplementaryCapability{
      id: "puppet:catalog_diff",
      slot: :node_tab,
      display_name: "Catalog diff",
      rbac_permission: "puppet:catalog_diff:view",
      data_contract: catalog_diff_schema(),
      ui_module: Vigil.Integrations.Puppet.UI.CatalogDiffTab
    },
    %SupplementaryCapability{
      id: "puppet:hiera_lookup",
      slot: :global_page,
      display_name: "Hiera key lookup",
      rbac_permission: "puppet:hiera_lookup:view",
      params_schema: hiera_lookup_params_schema(),
      ui_module: Vigil.Integrations.Puppet.UI.HieraLookupPage
    }
  ]
end
```

### 3.10.3 The slot registry

On plugin discovery, the platform builds `Vigil.Plugin.SlotRegistry` — an ETS table keyed by slot type with the discovered capability declarations:

```elixir
defmodule Vigil.Plugin.SlotRegistry do
  # ETS contents (keyed by :node_tab | :global_page | :node_action):
  #   {slot_type, [%SupplementaryCapability{plugin_id: ..., integration_id: ...}, ...]}

  def for_slot(:node_tab,    %{node_id: node_id, principal: p}), do: filtered(:node_tab, node_id, p)
  def for_slot(:node_action, %{node_id: node_id, principal: p}), do: filtered(:node_action, node_id, p)
  def for_slot(:global_page, %{principal: p}),                   do: filtered(:global_page, nil, p)

  defp filtered(slot, maybe_node_id, principal) do
    slot
    |> all_for_slot()
    |> Enum.filter(&plugin_linked_to_node?(&1, maybe_node_id))   # nil for global_page
    |> Enum.filter(&Vigil.Core.RBAC.permitted?(principal, &1.rbac_permission))
    |> Enum.filter(&integration_enabled?/1)
  end
end
```

The "plugin linked to this node" predicate consults `node_sources` for the viewed `node_id`: a `node_tab` from a Puppet plugin is shown only if the node has a `node_sources` row attributing it to that Puppet integration. For `global_page` this predicate is a no-op (always true — global pages are not per-node).

`PLUG-904` (plugin disabled or unhealthy): the registry filters out `node_tab` and `node_action` entries from disabled integrations; `global_page` entries remain but the dispatch path detects the unavailable integration and the LiveView renders the unavailable state instead of mounting the plugin's UI module.

### 3.10.4 Per-capability data calls

Supplementary capabilities follow the same dispatcher path as generic capabilities (`PLUG-809`):

```elixir
Vigil.Plugin.Dispatcher.supplementary_call(
  integration_id,
  "puppet:catalog_diff",
  args,
  opts
)
```

The dispatcher applies the same RBAC gate, circuit breaker, concurrency limiter, request coalescer, cache lookup, and deadline propagation as for generic capability calls. A failing supplementary capability does **not** affect rendering of generic tabs or other plugins' supplementary capabilities on the same page (`PLUG-809`) — each LiveComponent owns its own loading/error state per [§9.3.3](09-liveview-ui.md#933-livecomponents-for-encapsulated-state).

### 3.10.5 Conformance

`PLUG-811` extends the conformance suite (§3.7) with a supplementary-capability fixture:

- Asserts each declared capability ID is namespaced (`<plugin_id>:<rest>`).
- Asserts the `ui_module` is loaded and implements `Phoenix.LiveComponent`.
- Asserts the `rbac_permission` follows the platform's permission-name convention.
- Exercises the data-contract round-trip with a synthetic call to confirm the response matches `data_contract`.

## 3.11 Versioning and compatibility

`PLUG-601` through `PLUG-603`: the plugin contract is versioned as a semantic version, exposed as `Vigil.Plugin.contract_version/0`. The platform supports the current and previous major version concurrently.

On plugin load:

```elixir
case Version.compare(plugin.contract_version(), Vigil.Plugin.current_version()) do
  :eq -> load
  :lt -> if compatible?(plugin_major, current_major), do: load, else: refuse
  :gt -> refuse  # plugin targets a future version
end
```

The settings UI displays, per loaded plugin, which contract version it targets (`PLUG-603`). When the platform upgrades, incompatible plugins are flagged before they are initialized (`NFR-1202`).

---

[← Previous: Application Topology](02-application-topology.md) | [Next: Data Model →](04-data-model.md)

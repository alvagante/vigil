# 11. Puppet Integration — Detailed Design

This section describes the concrete design of the Puppet plugin, the most feature-rich integration. It realizes PRD section 7.

The plugin is an umbrella child application: `apps/vigil_integrations_puppet/`. It provides Inventory, Facts, Configuration (Hiera + catalogs + environments), Events, and Reports — but not Monitoring, Remote Execution, Provisioning, or Deployment.

## 11.1 Supervision tree

```
Vigil.Integrations.Puppet.Application
│
└── Vigil.Integrations.Puppet.Supervisor.<integration_id>
      │
      ├── Vigil.Integrations.Puppet.ConfigServer
      ├── Vigil.Integrations.Puppet.Health
      ├── Vigil.Integrations.Puppet.PuppetDB.Client        # Finch-backed HTTP
      ├── Vigil.Integrations.Puppet.Puppetserver.Client
      ├── Vigil.Integrations.Puppet.Hiera.Reader
      ├── Vigil.Integrations.Puppet.Hiera.UsageAnalyzer    # static analysis of control-repo
      ├── Vigil.Integrations.Puppet.ConcurrencyLimiter
      ├── Vigil.Integrations.Puppet.RequestCoalescer
      └── Vigil.Integrations.Puppet.FuseSupervisor         # :fuse breakers per sub-system
```

Each GenServer is named via the plugin registry:

```elixir
defp via(id, kind), do: {:via, Registry, {Vigil.Plugin.Registry, {:puppet, id, kind}}}
```

## 11.2 Sub-system clients

### 11.2.1 PuppetDB client

```elixir
defmodule Vigil.Integrations.Puppet.PuppetDB.Client do
  use GenServer

  def list_nodes(integration_id, query, opts) do
    GenServer.call(via(integration_id, :pdb_client),
                   {:query, build_nodes_query(query), opts},
                   opts[:deadline_ms] || 30_000)
  end

  def handle_call({:query, pql_or_ast, opts}, _from, state) do
    finch_request(state, method: :post,
                         path: "/pdb/query/v4",
                         body: Jason.encode!(%{query: pql_or_ast}),
                         opts: opts)
    |> respond_to(state)
  end
end
```

Uses Finch with per-integration connection pools. TLS verification enforced by default (`PUP-803`). mTLS (`PUP-801`) via Finch's `conn_opts: [transport_opts: [cert: ..., key: ..., cacertfile: ...]]`.

All queries are built as PQL (Puppet Query Language) for server-side filtering (`PUP-104`, `PUP-1102`). Pagination uses PQL's `limit` and `offset`, cursor-translated to a PQL construct on our side.

Example query construction:

```elixir
defp build_nodes_query(%{status: status, environment: env, fact_match: facts}) do
  clauses = [
    status && ~s|status = "#{status}"|,
    env && ~s|catalog_environment = "#{env}"|
  ] ++ Enum.map(facts, fn {k, v} -> ~s|facts { name = "#{k}" and value = "#{v}" }| end)

  "nodes[certname, deactivated, expired, latest_report_status] { #{Enum.join(clauses, " and ")} }"
end
```

PQL construction routes through a small builder (`Vigil.Integrations.Puppet.PQL`) with parameter escaping and composition. Ad-hoc string interpolation is forbidden by design (SQL-injection analog).

### 11.2.2 Puppetserver client

Puppetserver is used for catalog compilation (on-demand per `PUP-404`) and environment management (`PUP-501..508`).

```elixir
def compile_catalog(integration_id, node, environment) do
  # POST /puppet/v3/catalog/<node>?environment=<env>
end

def list_environments(integration_id) do
  # GET /puppet/v3/environments
end

def flush_environment_cache(integration_id) do
  # DELETE /puppet-admin-api/v1/environment-cache
end
```

Same mTLS, same Finch setup as PuppetDB. Catalog compilation is expensive and concurrency-limited per `PUP-1105`.

### 11.2.3 Hiera reader

Hiera data lives in a local copy of the control-repo (`PUP-301`, `7.5`). The `Reader` wraps file I/O:

```elixir
defmodule Vigil.Integrations.Puppet.Hiera.Reader do
  def read_hierarchy(integration_id, environment) do
    repo_path = config(integration_id).control_repo.path
    hiera_file = config(integration_id).hiera.config_file || "hiera.yaml"
    path = Path.join([repo_path, "environments", environment, hiera_file])
    with {:ok, contents} <- File.read(path),
         {:ok, yaml} <- YamlElixir.read_from_string(contents) do
      {:ok, normalize_hierarchy(yaml)}
    end
  end

  def resolve_key(integration_id, environment, key, node_context) do
    # Walks hierarchy, interpolates paths with node facts (%{facts.os.distro.codename}),
    # reads each level file, applies merge strategy.
  end
end
```

The Reader is read-only (`PUP-301` says Vigil MUST NOT modify the control-repo). File watches via `FileSystem` watcher invalidate cached hierarchy metadata when the control-repo updates (`PUP-1002`).

### 11.2.4 Hiera usage analyzer

The static analyzer (`PUP-331..334`) parses `.pp` files in the control-repo to find `lookup()` calls and class parameter definitions.

Options considered:

- **Full Puppet parser:** Most accurate. Requires implementing Puppet's parser in Elixir (expensive).
- **Shell out to `puppet parser dump`:** Requires Puppet binary on the host. Feasible but ties us to Puppet runtime availability.
- **Tree-sitter grammar:** Active Puppet grammar exists. We parse `.pp` files via tree-sitter bindings (`:tree_sitter_nif`) and extract `lookup()` calls and class parameter declarations.

> **Decision: Use `tree-sitter-puppet` via NIF.**
> It gives us a reasonable AST without shelling out to Puppet. Parsing a large control-repo (10,000+ lines) takes seconds — acceptable for a background analyzer. We cache results keyed by the control-repo's git HEAD, invalidating on change.

Results stored in ETS for quick queries; persisted to Postgres for durability across restarts:

```sql
CREATE TABLE puppet_hiera_key_usage (
  integration_id UUID NOT NULL REFERENCES integrations(id) ON DELETE CASCADE,
  key_name       TEXT NOT NULL,
  consumer_class TEXT NOT NULL,
  file_path      TEXT NOT NULL,
  line_number    INTEGER,
  usage_kind     TEXT NOT NULL,        -- 'lookup' | 'automatic_parameter_lookup'
  repo_revision  TEXT NOT NULL,
  PRIMARY KEY (integration_id, key_name, consumer_class, file_path, line_number)
);
```

The analyzer runs on:
- First startup (initial index).
- When FileSystem watcher fires (control-repo file changes).
- When admin triggers "refresh analysis" in the UI.

## 11.3 Capabilities

### 11.3.1 Inventory

```elixir
@impl Vigil.Plugin.Inventory
def list_nodes(integration_id, opts) do
  with {:ok, pdb_nodes}  <- PuppetDB.Client.list_nodes(integration_id, opts[:filter], opts),
       {:ok, ca_certs}   <- Puppetserver.Client.list_ca_certs(integration_id, opts),
       merged            <- merge_nodes_and_certs(pdb_nodes, ca_certs, opts[:show_deactivated]) do
    {:ok, %Result{data: merged, source: source(integration_id), fetched_at: DateTime.utc_now()}}
  end
end
```

Merges PuppetDB certnames with Puppetserver CA certificates (`PUP-102`, `PUP-103`). Both are shown — a node may be active in PuppetDB and revoked in CA; the user sees both states. CA status is a distinct attribute so `PUP-103` is satisfied.

Identity confidence (`PUP-106`):

```elixir
@impl Vigil.Plugin.Inventory
def identity_confidence do
  [
    %{attribute: :certname, level: :canonical},
    %{attribute: :fqdn, level: :strong},
    %{attribute: :hostname, level: :strong},
    %{attribute: :primary_ip, level: :unstable}
  ]
end
```

The linker weights Puppet's certname heavily.

### 11.3.2 Facts

```elixir
def get_facts(integration_id, node_identity, opts) do
  certname = require_certname!(node_identity)
  query = ~s|facts { certname = "#{certname}" }|
  PuppetDB.Client.query(integration_id, query, opts)
  |> normalize_facts()
end

def search_facts(integration_id, fact_query, opts) do
  # PQL: inventory[certname, facts] { facts { name = "os.distro.codename" and value = "jammy" } }
  PuppetDB.Client.search_facts(integration_id, fact_query, opts)
end
```

`PUP-205` (fact-based search via PQL) is a direct use of PuppetDB's inventory endpoint. Results paginated.

Fact authority:

```elixir
def fact_authority do
  %{
    authoritative: ~w(os.* kernel processors.* memory.* networking.* ipaddress* fqdn hostname domain),
    opportunistic: ~w(*)   # everything else
  }
end
```

`PUP-206` is satisfied by declaring these patterns. The platform's fact reconciler uses them to choose the reconciled value when sources disagree.

### 11.3.3 Configuration — Hiera

Three operations:

```elixir
def browse_hierarchy(integration_id, environment) do
  Hiera.Reader.read_hierarchy(integration_id, environment)
  |> enrich_with_keys_at_each_level()
end

def resolve_key(integration_id, environment, key, node_facts) do
  Hiera.Reader.resolve_key(integration_id, environment, key, node_facts)
end

def class_aware_lookup(integration_id, environment, node, class) do
  params = class_parameters(class, integration_id)
  Enum.map(params, fn param ->
    lookup_name = "#{class}::#{param.name}"
    case resolve_key(integration_id, environment, lookup_name, node.facts) do
      {:ok, result} -> %{param: param.name, from: :hiera, resolution: result}
      {:error, :not_found} ->
        case param.default do
          nil -> %{param: param.name, from: :unresolved}
          default -> %{param: param.name, from: :class_default, value: default}
        end
    end
  end)
end
```

The Reader implements `resolve_key/4` with:

1. **Interpolation** of hierarchy paths with `%{facts.*}` and `%{trusted.*}` references.
2. **Lookup** at each level in order.
3. **Merge** when strategy is `hash`, `unique`, or `deep`.
4. **Result** returns the full chain: which levels were consulted, which contributed, the merge strategy, the final value.

The data structure returned is rich:

```elixir
%HieraResolution{
  key: "webapp::enabled",
  result: %{value: true},
  merge_strategy: :first,
  chain: [
    %{level: "nodes/%{trusted.certname}.yaml",
      interpolated: "nodes/web-prod-01.example.com.yaml",
      status: :not_found},
    %{level: "environments/%{environment}.yaml",
      interpolated: "environments/production.yaml",
      status: :found, value: true}
  ]
}
```

The UI renders this chain directly (`PUP-312`).

### 11.3.4 Configuration — Catalogs

```elixir
def get_catalog(integration_id, node, environment, opts) do
  cond do
    opts[:force_compile] ->
      Puppetserver.Client.compile_catalog(integration_id, node, environment)
    true ->
      # PUP-401: prefer PuppetDB's stored catalog over Puppetserver compilation
      PuppetDB.Client.get_catalog(integration_id, node, environment)
  end
end

def diff_catalogs(integration_id, node, env_a, env_b, opts) do
  cat_a = get_catalog(integration_id, node, env_a, opts)
  cat_b = get_catalog(integration_id, node, env_b, opts)

  # Mode (a): both compiled on-demand from Puppetserver
  # Mode (b): latest from PuppetDB vs. freshly compiled from Puppetserver
  compute_diff(cat_a, cat_b)
end
```

Diff compares resource title+type tuples; for matching resources, compares parameter maps key-by-key. Output is a structured list:

```elixir
%CatalogDiff{
  only_in_a: [%Resource{...}],
  only_in_b: [%Resource{...}],
  changed: [
    %{resource: %Resource{...}, param_diffs: %{...}}
  ],
  identical_count: 230
}
```

The UI renders each section with color coding (additions green, removals red, changes yellow).

### 11.3.5 Configuration — Environments and code deployment

`PUP-504` (revised): the plugin supports **exactly two r10k / Code Manager operations** — deploy a single named environment, or deploy all environments. Module-level deploys (`r10k deploy module`) are explicitly out of scope and not exposed in the UI. The interface intentionally has no parameters beyond the environment name; there is no per-module variant.

```elixir
def list_environments(integration_id) do
  Puppetserver.Client.list_environments(integration_id)
  |> enrich_with_deploy_metadata()       # last_deploy_at, last_deploy_by, last_outcome
end

def flush_environment_cache(integration_id, environment) do
  Puppetserver.Client.flush_environment_cache(integration_id, environment)
end

@doc "Deploy a single named environment (PUP-504(a))."
def deploy_environment(integration_id, environment, principal)
    when is_binary(environment) and environment != "" do
  do_deploy(integration_id, {:single, environment}, principal)
end

@doc "Deploy all environments (PUP-504(b)). Same RBAC permission as deploy_environment/3."
def deploy_all_environments(integration_id, principal) do
  do_deploy(integration_id, :all, principal)
end

defp do_deploy(integration_id, scope, principal) do
  method = config(integration_id).code_deploy.method   # :code_manager | :r10k_webhook | :remote_exec

  result =
    case method do
      :code_manager  -> deploy_via_code_manager_api(integration_id, scope, principal)
      :r10k_webhook  -> deploy_via_webhook(integration_id, scope, principal)
      :remote_exec   -> deploy_via_exec_integration(integration_id, scope, principal)
    end

  record_deployment_journal_entry(result, integration_id, scope, principal)
  result
end
```

Notable interface choices:

- **No module deploy.** There is no `deploy_module/3` function and no UI affordance for module deploys. Operators who need per-module deploys do them via the underlying tooling outside Vigil. The Vigil model treats environment-level deploys as the unit of code change.
- **Deploy-all uses the same RBAC permission as deploy-single.** Per `PUP-509`, both operations require `puppet:environment:deploy`. There is no separate "bulk deploy" permission — the operational distinction is captured by the confirmation modal (deploy-all carries a higher-severity confirmation since it affects more environments), not by the permission model.
- **`PUP-507` (remote-exec fallback):** when the `:remote_exec` method is selected, the plugin calls `Vigil.Plugin.Dispatcher.call(exec_int_id, :execution, :run_command, %{command: "r10k deploy environment <env>"})` against a sibling execution integration. The plugin does **not** implement its own SSH or shell capability for this — clean reuse of the execution platform (`NFR-301`, single RBAC enforcement). For deploy-all, the command is `r10k deploy environment --all`.

#### Deployment outcome as journal entry (PUP-508)

Every deploy invocation records a journal entry against the Puppet integration capturing the outcome. The journal entry is *not* tied to any single node — it is an integration-scoped entry that surfaces in the global timeline filtered by source = puppet, and in the per-environment view of `puppet:environment_manager` (see [§11.3.7](#1137-supplementary-capabilities)).

```elixir
defp record_deployment_journal_entry({outcome, detail}, integration_id, scope, principal) do
  Vigil.Core.Journal.insert_integration_entry(%{
    integration_id: integration_id,
    occurred_at: DateTime.utc_now(),
    entry_type: "puppet.environment.deploy",
    severity: outcome_severity(outcome),
    summary: summary_for(scope, outcome),
    detail: Map.merge(detail, %{scope: scope, initiated_by: principal.id}),
    group_key: deploy_group_key(scope, detail)
  })
end

defp outcome_severity(:ok),       do: :informational
defp outcome_severity(:partial),  do: :warning
defp outcome_severity(:failed),   do: :error
```

Progress (live deploy output, when the `:remote_exec` method is in use) is streamed via the same execution PubSub pipeline as a regular execution — the deploy LiveView mounts the execution Stream GenServer for the underlying `r10k deploy ...` command and renders it inline. On completion, the deploy LiveView writes the consolidated journal entry above; the execution row itself is also persisted normally and is reachable via the back-reference in the journal entry's `detail.execution_id`.

### 11.3.6 Events and Reports

Events are fetched on-demand from PuppetDB via PQL when the user views the journal. The plugin's Events capability implements `fetch_events/3`:

```elixir
defmodule Vigil.Integrations.Puppet.Events do
  def fetch_events(config, node_certname, opts) do
    time_range = Keyword.fetch!(opts, :time_range)

    query = ~s|events[certname, timestamp, resource_type, resource_title, status,
               old_value, new_value, message, file, line, containment_path, report] {
              certname = "#{node_certname}"
              and timestamp >= "#{time_range.from}"
              and timestamp <= "#{time_range.to}"
              and status in ["success", "failure"]        # PUP-604: noop excluded
            }|

    case PuppetDB.Client.query(config.integration_id, query, timeout: 30_000) do
      {:ok, events} ->
        {:ok, Enum.map(events, &normalize_event(&1, config.integration_id))}
      {:error, _} = err ->
        err
    end
  end

  defp normalize_event(event, integration_id) do
    %{
      source_event_id: "#{event["report"]}:#{event["resource_type"]}[#{event["resource_title"]}]",
      occurred_at: parse_timestamp(event["timestamp"]),
      entry_type: "configuration_change",
      summary: "#{event["resource_type"]}[#{event["resource_title"]}]: #{event["message"]}",
      severity: if(event["status"] == "failure", do: :error, else: :informational),
      detail: %{
        resource_type: event["resource_type"],
        resource_title: event["resource_title"],
        old_value: event["old_value"],
        new_value: event["new_value"],
        file: event["file"],
        line: event["line"],
        containment_path: event["containment_path"]
      },
      group_key: event["report"],
      references: %{report_id: event["report"]}
    }
  end
end
```

Each event is normalized with:
- `group_key = report_id` (all events from one run grouped — `PUP-603`, `JRN-005`).
- `references = %{report_id: ...}` for drill-back to the report detail view.

Reports are fetched on-demand via the Reports capability. When the user navigates to a report detail view, the full report is fetched from PuppetDB and rendered. No local storage of reports or events — PuppetDB is the source of truth.

> **Note:** There is no EventPoller, no webhook handler for journal ingestion, and no checkpoint tracking. Events are fetched fresh from PuppetDB each time the journal is viewed. PuppetDB's own retention policy governs how far back events are available.

### 11.3.7 Supplementary capabilities

Per PRD §6.7 (`PLUG-801`..`PLUG-811`) and the manifest declaration described in design/03 §3.10, the Puppet plugin declares seven supplementary capabilities. Each is independently RBAC-gated and hidden entirely when the user lacks the required permission (`PLUG-806`).

```elixir
defmodule Vigil.Integrations.Puppet do
  @behaviour Vigil.Plugin

  @impl Vigil.Plugin
  def supplementary_capabilities do
    [
      cap("puppet:catalog_view",            :node_tab,    "Catalog",
          "puppet:catalog_view:view",       UI.CatalogViewTab),
      cap("puppet:catalog_diff",            :node_action, "Catalog diff",
          "puppet:catalog_diff:run",        UI.CatalogDiffAction),
      cap("puppet:hiera_lookup",            :node_tab,    "Hiera lookup",
          "puppet:hiera_lookup:view",       UI.HieraLookupTab),
      cap("puppet:hiera_explorer",          :global_page, "Hiera explorer",
          "puppet:hiera_explorer:view",     UI.HieraExplorerPage),
      cap("puppet:node_list_by_environment",:global_page, "Nodes by environment",
          "puppet:node_list:view",          UI.NodeListByEnvironmentPage),
      cap("puppet:code_analysis",           :global_page, "Code analysis",
          "puppet:code_analysis:view",      UI.CodeAnalysisPage),
      cap("puppet:environment_manager",     :global_page, "Environments",
          "puppet:environment:view",        UI.EnvironmentManagerPage)
    ]
  end
end
```

| Capability ID | Slot | UI module | Data source | RBAC permission |
|---------------|------|-----------|-------------|-----------------|
| `puppet:catalog_view` | `node_tab` | `Vigil.Integrations.Puppet.UI.CatalogViewTab` | `Puppetserver.Client.compile_catalog/3` (§11.2.2) — cached per `{node, environment, code_version}` | `puppet:catalog_view:view` |
| `puppet:catalog_diff` | `node_action` | `Vigil.Integrations.Puppet.UI.CatalogDiffAction` | Two `compile_catalog` calls + diff via `Vigil.Integrations.Puppet.CatalogDiff` | `puppet:catalog_diff:run` |
| `puppet:hiera_lookup` | `node_tab` | `Vigil.Integrations.Puppet.UI.HieraLookupTab` | `Hiera.Reader.lookup/3` with node facts as the lookup context | `puppet:hiera_lookup:view` |
| `puppet:hiera_explorer` | `global_page` | `Vigil.Integrations.Puppet.UI.HieraExplorerPage` | `Hiera.UsageAnalyzer` cross-referenced with current values from `Hiera.Reader` | `puppet:hiera_explorer:view` |
| `puppet:node_list_by_environment` | `global_page` | `Vigil.Integrations.Puppet.UI.NodeListByEnvironmentPage` | PQL: `nodes { ... } order by catalog_environment, certname` | `puppet:node_list:view` |
| `puppet:code_analysis` | `global_page` | `Vigil.Integrations.Puppet.UI.CodeAnalysisPage` | `Hiera.UsageAnalyzer` results (orphan keys, unused classes, etc.) | `puppet:code_analysis:view` |
| `puppet:environment_manager` | `global_page` | `Vigil.Integrations.Puppet.UI.EnvironmentManagerPage` | `list_environments/1` (§11.3.5) + recent deploy journal entries | `puppet:environment:view` (read) + `puppet:environment:deploy` (action) |

Slot-mount rules per design/03 §3.10:

- `node_tab` and `node_action` slots mount only when the Puppet plugin is linked to the viewed node (i.e., `node_sources` carries a row attributing the node to this integration). A node reported only by AWS will not see Puppet's `catalog_view` tab even when the integration is healthy.
- `global_page` slots are accessible whenever the integration is enabled and the user has the permission. They render an unavailable state when the integration is disabled or unhealthy (`PLUG-904`).

All seven capabilities flow through `Vigil.Plugin.Dispatcher.supplementary_call/4` (design/03 §3.10.4) — same caching, circuit breaker, concurrency limiter, and deadline propagation as generic capability calls. The `environment_manager` page's deploy action is the one writeable surface among the seven; it goes through `deploy_environment/3` / `deploy_all_environments/2` (§11.3.5) and inherits their audit and journal behaviour.

## 11.4 Caching

Per `PUP-1001`:

| Capability | Default TTL |
|------------|-------------|
| Inventory | 15 minutes |
| Facts | 30 minutes |
| Reports (recent) | 5 minutes |
| Reports (historical, > 1h old) | 1 hour |
| Catalog | 30 minutes |
| Hiera hierarchy | 15 minutes |
| Hiera resolution | 15 minutes |
| Usage analysis | invalidated on git HEAD change |

Cache invalidation events:

- `flush_environment_cache` → invalidates Puppetserver catalog cache + Vigil's catalog cache for that environment.
- Control-repo file change (FileSystem watcher) → invalidates Hiera resolution cache, usage analysis cache.
- User clicks "refresh" → full flush for the selected scope (`PUP-1005`).

## 11.5 Health checks

`Health` worker probes each sub-system independently:

```elixir
def perform_health_check(integration_id) do
  results = %{
    puppetdb:      probe_puppetdb(integration_id),
    puppetserver:  probe_puppetserver(integration_id),
    control_repo:  probe_control_repo(integration_id)
  }

  derive_per_capability_status(results)
end

defp probe_puppetdb(id) do
  case PuppetDB.Client.query(id, "nodes[certname] { order by certname limit 1 }", timeout: 5_000) do
    {:ok, _} -> :healthy
    {:error, :timeout} -> :degraded
    {:error, _} -> :unhealthy
  end
end

defp probe_control_repo(id) do
  path = config(id).control_repo.path
  case File.stat(path) do
    {:ok, _} -> :healthy
    {:error, _} -> :unhealthy
  end
end

defp derive_per_capability_status(%{puppetdb: pdb, puppetserver: pss, control_repo: cr}) do
  %{
    inventory: worst_of([pdb, pss]),
    facts: pdb,
    configuration: %{
      hiera: cr,
      catalogs: worst_of([pdb, pss]),
      environments: pss
    },
    events: pdb,
    reports: pdb
  }
end
```

Per-capability health (`PUP-902`, `PUP-903`, `RES-203`) lets the UI gray out only failing sections while leaving others functional.

`PUP-002`, `PUP-003`: the plugin continues to serve capabilities served by healthy sub-systems. PuppetDB only? Inventory/Facts/Events/Reports work; Configuration is degraded. Puppetserver + Hiera only? Configuration works; Inventory/Facts/Events/Reports are degraded (served from stale cache or not at all).

## 11.6 Configuration schema

Matches `PUP-1201..1203` and section 7.14 of the PRD. The schema is declared in `Vigil.Integrations.Puppet.config_schema/0`. The admin UI renders each field with its description, validation, and "test connection" (`UI-803`, `PUP-1203`):

```elixir
def config_schema do
  %Vigil.Plugin.Schema{
    fields: [
      %Field{name: "puppetdb.url", type: :url, required: false,
             description: "Base URL of PuppetDB. Leave blank to disable PuppetDB."},
      %Field{name: "puppetdb.client_cert", type: :path_or_secret_ref, secret?: true,
             conditional_on: "puppetdb.url"},
      # ...
      %Field{name: "control_repo.path", type: :path, required: false,
             description: "Local path to the Puppet control-repo checkout. Read-only."},
      # ...
    ]
  }
end
```

The `validators` field on each `Field` includes callable checks like `url_reachable?`, `file_exists?`, `valid_cert?`.

## 11.7 RBAC permissions

Per `PUP-1301..1310`:

- `puppet:inventory:read`
- `puppet:facts:read`
- `puppet:configuration:read`
- `puppet:events:read`
- `puppet:reports:read`
- `puppet:environment:flush_cache`
- `puppet:environment:deploy`
- `puppet:catalog:diff`

Each is registered at plugin load time via `Vigil.Core.RBAC.register_permissions/1`. The default `operator` role receives the read permissions; `administrator` receives all; `auditor` receives reads only.

## 11.8 Performance at 10,000 nodes

| Scenario | Approach |
|----------|----------|
| List 10,000-node inventory | PuppetDB `nodes[certname]` query with paginated certname iteration; ~800ms cold |
| Facts for 10,000 nodes | Not done in bulk — per-node queries via cache lookups; facts search via PQL with predicate pushdown |
| Full report sweep | On-demand PQL query with time-range filter; response time depends on PuppetDB retention volume |
| Catalog diff | On-demand Puppetserver call per side; concurrency-limited to avoid flooding |
| Hiera resolution | File reads on a warm page cache are sub-millisecond; resolution cache for repeated queries |

At 10,000 nodes, PuppetDB and Puppetserver themselves are typically the bottleneck, not our plugin. We stay out of their way — no bulk materialization, no re-fetching unchanged data, no excessive concurrency.

## 11.9 Journal contributions

Per `PUP-1401..1404`:

| Source | Journal contribution |
|--------|---------------------|
| Resource events from reports | 1 entry per event; grouped by report |
| Environment deployment | 1 entry per deployment (Vigil-initiated) |
| Environment cache flush | 1 entry per flush (Vigil-initiated) |
| Failed reports (compile errors) | 1 entry summarizing the failure |

No-op runs produce no entries. Report ingestion writes the report row first and the events second, in the same transaction, so the report is always navigable from its entries.

## 11.10 Acceptance criteria alignment

PRD section 7.17's 15 criteria map 1:1 to test suites under `apps/vigil_integrations_puppet/test/`. Each criterion has at least one integration test running against a containerized PuppetDB/Puppetserver pair in CI. See [section 13](13-testing-strategy.md) for the fixture approach.

## 11.11 Patterns for other plugins

Though this section describes Puppet specifically, the patterns generalize:

- **Supervisor tree per integration instance**, clients as children.
- **Finch client with mTLS** where the upstream supports it.
- **Per-sub-system health**, derived to per-capability health.
- **Checkpointed event polling** with PQL-like server-side filtering.
- **Request coalescing and caching** via the dispatcher.
- **Schema-driven config** with UI-visible fields and validators.
- **Plugin-specific extensions** (usage analyzer, tree-sitter parsing) as optional background workers.

Bolt, Ansible, SSH, Proxmox, AWS, and Azure plugins all follow this shape. Their specifics (CLI vs. API, identity confidence profiles, caching TTLs) differ; their skeleton does not.

---

[← Previous: MCP & AI](10-mcp-and-ai.md) | [Next: Ansible Integration →](14-ansible-integration.md)

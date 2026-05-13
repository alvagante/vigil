# 14. Ansible Integration — Detailed Design

This section describes the concrete design of the Ansible plugin. It realizes PRD section 8.3 (`ANS-101`..`ANS-1102`).

The plugin is an umbrella child application: `apps/vigil_integrations_ansible/`. It provides **Inventory**, **Facts**, and **Remote Execution** — and explicitly does **not** declare Monitoring, Configuration, Events, Provisioning, or Deployment capabilities (`ANS-101` opening note). Unlike Puppet, Ansible has no persistent server-side fact or run history; Vigil compensates by caching gathered facts and persisting execution transcripts (`DM-1103`).

Each configured integration instance operates against one **Ansible project directory** containing an inventory source and playbooks (`ANS-104`). Multiple independent projects are independent integrations.

## 14.1 Supervision tree

```
Vigil.Integrations.Ansible.Application
│
└── Vigil.Integrations.Ansible.Supervisor.<integration_id>
      │
      ├── Vigil.Integrations.Ansible.ConfigServer
      ├── Vigil.Integrations.Ansible.Health
      ├── Vigil.Integrations.Ansible.InventoryParser    # parses ansible-inventory --list
      ├── Vigil.Integrations.Ansible.VariableResolver   # walks host_vars / group_vars
      ├── Vigil.Integrations.Ansible.VaultDetector       # scans for `!vault` markers
      ├── Vigil.Integrations.Ansible.PlaybookDiscovery  # enumerates *.yml at project root
      ├── Vigil.Integrations.Ansible.ProjectWatcher     # FileSystem watcher for invalidation
      ├── Vigil.Integrations.Ansible.ConcurrencyLimiter
      ├── Vigil.Integrations.Ansible.RequestCoalescer
      └── Vigil.Integrations.Ansible.FuseSupervisor     # :fuse breakers per sub-system
```

Process registration follows the plugin convention:

```elixir
defp via(id, kind), do: {:via, Registry, {Vigil.Plugin.Registry, {:ansible, id, kind}}}
```

Each GenServer is restartable; the `Supervisor` strategy is `:one_for_one` because the children have no shared state — losing the `PlaybookDiscovery` worker does not invalidate `VariableResolver`'s parse cache.

## 14.2 Sub-system clients

### 14.2.1 CLI runner

Every external call shells out to `ansible`, `ansible-playbook`, `ansible-inventory`, or `ansible-galaxy`. The runner is the shared platform `Vigil.Plugin.CLIRunner` (design/05 §5.7.1) with Ansible-specific argument construction:

```elixir
defmodule Vigil.Integrations.Ansible.CLI do
  alias Vigil.Plugin.CLIRunner

  def inventory_list(config) do
    CLIRunner.run(config.ansible_inventory_executable,
                  ["--list", "-i", config.inventory] ++ vault_args(config),
                  wall_clock_ms: 60_000, idle_ms: 30_000,
                  env: ansible_env(config))
  end

  def inventory_host(config, hostname) do
    CLIRunner.run(config.ansible_inventory_executable,
                  ["--host", hostname, "-i", config.inventory] ++ vault_args(config),
                  wall_clock_ms: 30_000, idle_ms: 15_000,
                  env: ansible_env(config))
  end

  def setup(config, target_pattern, opts) do
    CLIRunner.run(config.ansible_executable,
                  [target_pattern, "-i", config.inventory,
                   "-m", "setup",
                   "--forks", to_string(opts.forks)] ++ vault_args(config),
                  wall_clock_ms: opts.wall_clock_ms,
                  idle_ms: opts.idle_ms,
                  env: ansible_env(config))
  end

  def playbook(config, playbook_path, target_pattern, opts) do
    args = ["-i", config.inventory,
            "--forks", to_string(opts.forks),
            playbook_path] ++
           extra_vars_args(opts.extra_vars) ++
           tag_args(opts.tags, opts.skip_tags) ++
           mode_args(opts) ++
           vault_args(config)

    CLIRunner.run(config.ansible_playbook_executable, args,
                  wall_clock_ms: opts.wall_clock_ms,
                  idle_ms: opts.idle_ms,
                  env: ansible_env(config))
  end

  defp ansible_env(config) do
    %{
      "ANSIBLE_STDOUT_CALLBACK" => "json",        # ANS-407: structured per-task output
      "ANSIBLE_LOAD_CALLBACK_PLUGINS" => "True",
      "ANSIBLE_HOST_KEY_CHECKING" => host_key_checking(config),
      "ANSIBLE_FORCE_COLOR" => "False",            # transcripts are not terminal-coloured
      "ANSIBLE_DEPRECATION_WARNINGS" => "False"
    }
    |> add_vault_password_env(config)
  end
end
```

`ANS-507`: when `ANSIBLE_HOST_KEY_CHECKING` resolves to `False`, the `Health` worker raises a warning surfaced in the admin UI. The plugin never silently disables host key checking on its own; it only forwards user-configured intent.

### 14.2.2 Inventory parser

`ansible-inventory --list` returns a single JSON document for the whole inventory. For 5,000-host inventories (`ANS-801`), that JSON can run into tens of MB. The parser streams the JSON via `Jaxon` so the entire document does not need to be materialized at once (`ANS-804`):

```elixir
defmodule Vigil.Integrations.Ansible.InventoryParser do
  use GenServer

  def refresh(integration_id, opts \\ []) do
    GenServer.call(via(integration_id, :inventory_parser),
                   {:refresh, opts}, opts[:deadline_ms] || 90_000)
  end

  def handle_call({:refresh, opts}, _from, state) do
    with {:ok, port} <- Ansible.CLI.inventory_list_stream(state.config),
         {:ok, parsed} <- Jaxon.Stream.from_port(port) |> parse_inventory_stream() do
      observations = build_observations(parsed, state.integration_id)
      publish_observations(state.integration_id, observations)   # → linker
      {:reply, {:ok, length(observations)}, %{state | last_parse: parsed}}
    end
  end
end
```

`publish_observations/2` emits `{:integration_cache_refreshed, integration_id, observations}` on the `inventory:cache_refreshed` PubSub topic. The `Vigil.Core.Inventory.Linker` consumes the topic (design/05 §5.2.4) and updates the multi-attribute inverted index incrementally.

`ANS-106` linking confidence is declared in the plugin module:

```elixir
@impl Vigil.Plugin.Inventory
def identity_confidence do
  [
    %{attribute: :primary_ip, level: :strong},   # ansible_host when resolvable
    %{attribute: :hostname,   level: :best_effort}
  ]
end
```

`ANS-107`: when the inventory CLI exits non-zero, the parser does **not** update the cache and does **not** rebuild the linker index. The previous valid inventory remains served with a staleness marker via the standard `:stale` freshness tag (design/05 §5.3.3) and the integration's health transitions to `:unhealthy` with a diagnostic naming the inventory file.

### 14.2.3 Variable resolver

`ANS-301`..`ANS-307` require per-node variable resolution with the full precedence chain. Two layers of source data:

1. **Static parsing** of `host_vars/` and `group_vars/` directories (`ANS-303`) — YAML/JSON files producing the lower-precedence layers.
2. **Live `ansible-inventory --host <name>`** — produces the merged effective variable set as Ansible itself would compute it.

The resolver combines both: it parses the static files to attribute each variable to its file of origin (which `ansible-inventory --host` does not expose), then validates against the live merged view to ensure the parse is consistent.

```elixir
defmodule Vigil.Integrations.Ansible.VariableResolver do
  use GenServer

  def for_node(integration_id, node_name) do
    GenServer.call(via(integration_id, :variable_resolver),
                   {:for_node, node_name}, 30_000)
  end

  def search(integration_id, var_name) do
    GenServer.call(via(integration_id, :variable_resolver),
                   {:search, var_name}, 30_000)
  end

  def handle_call({:for_node, node_name}, _from, state) do
    with {:ok, static_layers} <- StaticParser.layers_for(state.project_dir, node_name),
         {:ok, effective}     <- Ansible.CLI.inventory_host(state.config, node_name),
         resolved             <- build_precedence_chain(static_layers, effective) do
      {:reply, {:ok, redact_vault(resolved)}, state}
    end
  end
end
```

`build_precedence_chain/2` produces, per variable name, an ordered list of `%{layer, source_path, value, winner?}` entries — exactly the shape the `ansible:variable_lookup` supplementary capability needs.

`ANS-304` vault redaction: the `StaticParser` runs each YAML scalar through a `vault_marker?/1` test that recognises `!vault` tags and the multi-line `$ANSIBLE_VAULT;...` envelope. Matches are replaced with `:encrypted` and never passed through the rest of the pipeline. Decrypt-on-demand is available when `vault_password_file` or `vault_password_command` is configured (`ANS-503`); the decrypted value is held only for the duration of one LiveView response and is **not** cached.

`ANS-704` invalidation: the `ProjectWatcher` GenServer subscribes to `FileSystem` notifications on `host_vars/` and `group_vars/`. On any change it broadcasts `{:variables_changed, integration_id, [paths]}` and the `VariableResolver` flushes its parse cache.

`ANS-305` (cross-inventory search) is the data source for the `ansible:variable_explorer` supplementary capability — see [§14.3.6](#1436-supplementary-capabilities).

### 14.2.4 Playbook discovery

`ANS-403`: the plugin discovers playbooks by enumerating `*.yml` / `*.yaml` at the project root and one level deep. Discovery is bounded — the plugin does not walk arbitrary subdirectories so that role tasks are not misidentified as top-level playbooks.

```elixir
defmodule Vigil.Integrations.Ansible.PlaybookDiscovery do
  def discover(project_dir) do
    candidates = Path.wildcard(Path.join(project_dir, "*.{yml,yaml}")) ++
                 Path.wildcard(Path.join(project_dir, "*/*.{yml,yaml}"))
    candidates
    |> Enum.reject(&role_directory?/1)
    |> Enum.map(&extract_metadata/1)
    |> Enum.filter(&playbook?/1)
  end

  defp extract_metadata(path) do
    {:ok, yaml} = YamlElixir.read_from_file(path)
    %{
      path: path,
      name: List.first(yaml)["name"] || Path.basename(path, ".yml"),
      hosts: List.first(yaml)["hosts"],
      tags: collect_tags(yaml),
      vars_prompt: collect_vars_prompt(yaml),    # ANS-404 — for form generation
      task_count: count_tasks(yaml)
    }
  end
end
```

`role_directory?/1` excludes files inside `roles/`, `collections/`, and `ansible_collections/` — Ansible's structural conventions. A file matching `*/tasks/*.yml` is not a playbook.

### 14.2.5 Galaxy roles

`ANS-411`: `ansible-galaxy list` is invoked at startup and on demand. Output is parsed into a structured list cached for the integration's lifetime, with the `:requirements.yml` mtime used as the invalidation trigger.

## 14.3 Capabilities

### 14.3.1 Inventory

```elixir
@impl Vigil.Plugin.Inventory
def list_nodes(integration_id, _opts) do
  case Cache.get({integration_id, :inventory, :list}) do
    {:ok, %CacheEntry{} = entry} -> {:ok, entry}
    :miss -> InventoryParser.refresh(integration_id)
  end
end
```

Inventory is cached per integration with a 15-minute default TTL (`ANS-701`). The `ProjectWatcher` invalidates the cache on inventory file changes. Scheduled refresh is driven by an Oban cron job in the `maintenance` queue (`ANS-108`); per-integration cache flush is exposed via `PLUG-013` / `ANS-908`.

Group hierarchy (`ANS-102`): the parser preserves Ansible's `children` relationships and emits `Vigil.Plugin.Group` records carrying `hierarchy_parent`. The `all` and `ungrouped` groups are emitted explicitly and tagged so the LiveView can render them distinctly (or hide them if the operator prefers).

Connection metadata (`ANS-105`) — `ansible_user`, `ansible_port`, `ansible_become*`, `ansible_connection` — is captured into `Vigil.Plugin.Node.metadata` for display on the node detail page without exposing the values through the inventory list endpoint.

### 14.3.2 Facts

Two source modes per `ANS-201` / `ANS-204`:

| Mode | Trigger | Backing call |
|------|---------|-------------|
| Live `setup` | Default on cache miss / explicit refresh | `ansible <target> -m setup` via CLI |
| Ansible fact cache backend | `fact_cache_backend` configured | Read directly from the configured backend (jsonfile / redis / yaml) |

```elixir
@impl Vigil.Plugin.Facts
def for_node(integration_id, node_name, opts) do
  config = ConfigServer.get(integration_id)

  cond do
    config.fact_cache_backend != nil ->
      FactCacheBackend.read(config.fact_cache_backend, node_name)
      |> tag_freshness(:from_ansible_fact_cache)

    true ->
      live_setup(integration_id, node_name, opts)
  end
end
```

`ANS-205`: the plugin declares itself authoritative for the `ansible_*` namespace and opportunistic elsewhere (e.g., custom facts from `facts.d`). This populates the `authority` column on the per-fact attribution path in design/04 §4.3.

`ANS-202`: the plugin does **not** schedule automatic fact gathering across all hosts. The Oban cron job that *can* exist for facts is opt-in and operator-configured per integration; the default is no scheduled gathering. A LiveView opening the node detail's Facts tab triggers an on-demand fetch if the cache is cold.

`ANS-207`: per-target failures during batch `setup` are captured per host. The structured JSON callback emits per-host results; partial success is the default outcome rather than an all-or-nothing.

`ANS-208` normalization: a small `Normalizer` module maps Ansible's fact namespace onto the platform's common schema:

```elixir
defp normalize(ansible_facts) do
  %{
    "os.distribution"      => ansible_facts["ansible_distribution"],
    "os.distribution.version" => ansible_facts["ansible_distribution_version"],
    "kernel"               => ansible_facts["ansible_kernel"],
    "hostname"             => ansible_facts["ansible_hostname"],
    "fqdn"                 => ansible_facts["ansible_fqdn"],
    "ip.addresses"         => ansible_facts["ansible_all_ipv4_addresses"],
    "cpu.count"            => ansible_facts["ansible_processor_vcpus"],
    "memory.total_mb"      => ansible_facts["ansible_memtotal_mb"]
  }
end
```

These mapped values are co-presented with the raw `ansible_*` values in the source-badged facts table (design/09 §9.7.1).

### 14.3.3 Variable resolution

Variable resolution is not one of the nine generic integration types — it is consumed exclusively through the `ansible:variable_lookup` (node) and `ansible:variable_explorer` (global) supplementary capabilities. The implementation lives in `VariableResolver` (§14.2.3).

`ANS-307`: the resolver is keyed by `integration_id` throughout. The static parser uses paths under the configured `project_dir` only — a second Ansible integration with its own project_dir has its own resolver state.

### 14.3.4 Remote execution

The plugin implements `Vigil.Plugin.Execution`. The runner module is the per-execution-group child mounted by `Vigil.Core.Execution.Stream` (design/06 §6.2.4):

```elixir
defmodule Vigil.Integrations.Ansible.Execution.Runner do
  @behaviour Vigil.Plugin.Execution.Runner

  @impl true
  def start(integration_id, artifact, targets, opts) do
    case artifact.kind do
      :command  -> start_ad_hoc(integration_id, artifact, targets, opts)
      :playbook -> start_playbook(integration_id, artifact, targets, opts)
      :package  -> start_package(integration_id, artifact, targets, opts)
    end
  end

  @impl true
  def abort(ref), do: Port.close(ref.port)
end
```

#### Ad-hoc (`ANS-401`)

```elixir
defp start_ad_hoc(integration_id, %{module: mod, args: args}, targets, opts) do
  pattern = targets_to_pattern(targets)
  Ansible.CLI.adhoc(config(integration_id),
                    pattern: pattern, module: mod || "shell", args: args,
                    forks: opts.forks, wall_clock_ms: opts.wall_clock_ms,
                    idle_ms: opts.idle_ms)
end
```

The module defaults to `shell` (`ANS-401`); operators may select `command` or `raw` per execution.

#### Playbook (`ANS-402` / `ANS-405`)

The runner forwards user-supplied options: `extra_vars`, `tags`, `skip_tags`, `check`, `diff`, `verbosity`. The JSON callback (`ANSIBLE_STDOUT_CALLBACK=json`) emits one structured event per task per host. The runner consumes the JSON stream line-by-line and forwards per-target chunks to the Stream GenServer:

```elixir
defp parse_callback_line(line, state) do
  case Jason.decode(line) do
    {:ok, %{"event" => "runner_on_ok", "event_data" => %{"host" => h} = data}} ->
      send_chunk(state, h, :stdout, format_task_ok(data))
      record_task_outcome(state, h, :ok)

    {:ok, %{"event" => "runner_on_failed", "event_data" => %{"host" => h} = data}} ->
      send_chunk(state, h, :stderr, format_task_failure(data))
      record_task_outcome(state, h, :failed)

    {:ok, %{"event" => "runner_on_unreachable", "event_data" => %{"host" => h}}} ->
      record_task_outcome(state, h, :unreachable)

    # ... runner_on_skipped, playbook_on_play_start, playbook_on_stats, etc.
  end
end
```

`ANS-409` PLAY RECAP: the final `playbook_on_stats` event carries the per-host ok/changed/failed/skipped/unreachable counts. These are stamped into `executions.metadata.play_recap` on each per-target row (design/04 §4.5.2) so the execution detail page can render the recap as structured data rather than parsing the transcript.

`ANS-407`: the raw transcript is preserved in full alongside the structured per-task data. The user can switch between "structured" and "raw" views in the LiveView.

`ANS-406` per-target attribution: a chunk's `target_id` is resolved by looking up the `executions` row whose `target_identity.ansible_host` matches the host name in the JSON event. The resolution is done once in the runner's startup with a map; per-chunk it is an O(1) lookup.

`ANS-412` mixed outcomes: per-target outcomes track the worst-event-seen state per host. A host with at least one `failed` task ends as `failed`; otherwise `unreachable` if there was an unreachable event, otherwise `ok`. The group's overall summary is computed at completion from the per-target outcomes (design/04 §4.5.4).

#### Package management (`ANS-410`)

The package action wraps `ansible -m package -a "name=<pkg> state=<present|absent|latest>"`. The user selects the package operation via UI; the runner translates it into the same `start_ad_hoc/4` path with `module: "package"`.

### 14.3.5 Authentication and transport

`ANS-501`..`ANS-507`: the plugin defers entirely to Ansible's own connection configuration. Vigil supplies:

- `vault_password_file` / `vault_password_command` in the CLI arguments and as `ANSIBLE_VAULT_PASSWORD_FILE` environment variable when required (`ANS-503`). The vault credential is resolved through `Vigil.Core.Secrets` (design/03 §3.2.4).
- `become_user` / `become_method` as `ANSIBLE_BECOME_USER` / `ANSIBLE_BECOME_METHOD` defaults (`ANS-504`), overridable by inventory.
- The execution environment is otherwise unmodified. Connection plugins beyond SSH (`docker`, `kubectl`, `winrm`, `local`) work to the extent that the operator has installed and configured them in Ansible itself (`ANS-505` / `ANS-506`).

The plugin **never** edits `ansible.cfg`. The expectation is that the operator manages Ansible's own configuration; Vigil consumes whatever the project already has.

### 14.3.6 Supplementary capabilities

The Ansible plugin declares four supplementary capabilities per PRD §8.3.1 (the supplementary table):

```elixir
@impl Vigil.Plugin
def supplementary_capabilities do
  [
    cap("ansible:variable_lookup",   :node_tab,    "Variables",
        "ansible:variables:read",    UI.VariableLookupTab),
    cap("ansible:variable_explorer", :global_page, "Variable explorer",
        "ansible:variables:read",    UI.VariableExplorerPage),
    cap("ansible:role_browser",      :global_page, "Roles & collections",
        "ansible:inventory:read",    UI.RoleBrowserPage),
    cap("ansible:playbook_history",  :global_page, "Playbook history",
        "ansible:playbook:execute",  UI.PlaybookHistoryPage)
  ]
end
```

| Capability ID | Slot | Data source | RBAC |
|---------------|------|-------------|------|
| `ansible:variable_lookup` | `node_tab` | `VariableResolver.for_node/2` — full precedence chain per variable | `ansible:variables:read` |
| `ansible:variable_explorer` | `global_page` | `VariableResolver.search/2` — cross-inventory by variable name | `ansible:variables:read` |
| `ansible:role_browser` | `global_page` | `GalaxyRoles.list/1` + parsed `meta/main.yml` per role | `ansible:inventory:read` |
| `ansible:playbook_history` | `global_page` | Ecto query against `executions` filtered by `plugin_id = "ansible"`, grouped by `artifact_name`, joined with per-node success trends | `ansible:playbook:execute` |

`ANS-910`: `ansible:variables:read` is intentionally separate from `ansible:facts:read` because host_vars and group_vars may contain operational secrets or credentials that operators do not expose to fact-readers. This separation is enforced both by the supplementary capability's RBAC permission and by the `VariableResolver` requiring an explicit permission check on every call.

Mounting follows the platform rules (design/03 §3.10): `variable_lookup` is mounted only when the Ansible plugin is linked to the viewed node; the three `global_page` capabilities are accessible whenever the integration is enabled.

## 14.4 Caching

| Capability | Default TTL | Source | Invalidation |
|------------|-------------|--------|--------------|
| Inventory | 15 min (`ANS-701`) | `ansible-inventory --list` | TTL; `ProjectWatcher` on inventory file change; manual flush |
| Facts (live) | 1 hour (`ANS-701`) | `ansible <target> -m setup` | TTL; manual flush; user-triggered refresh |
| Facts (Ansible cache) | follows backend expiry (`ANS-703`) | Configured backend | Backend's own expiry; manual flush only invalidates Vigil's view |
| Variable resolution | 15 min (`ANS-701`) | Static files + `ansible-inventory --host` | TTL; `ProjectWatcher` on host_vars/group_vars change; manual flush |
| Playbook discovery | until project changes | Filesystem scan + parsed YAML | `ProjectWatcher` on project_dir change |
| Galaxy roles | until requirements change | `ansible-galaxy list` + parsed `meta/main.yml` | mtime of `requirements.yml` |

All caches honour the shared-cache model from revised `CACHE-006` (design/05 §5.3): entries hold the full unfiltered response; RBAC target-scope filtering happens at presentation time.

`PLUG-013` / `ANS-908`: every cache is flushable via `Vigil.Plugin.Dispatcher.flush(integration_id, :all | <capability>)`. The flush is RBAC-gated by the dedicated `ansible:cache:flush` permission.

## 14.5 Health checks

`ANS-604` / `ANS-605`: the `Health` worker probes the integration every 30 s by default (`PLUG-111`). Probe content:

```elixir
defp probe(state) do
  %{
    overall: aggregate(...),
    checked_at: DateTime.utc_now(),
    capabilities: %{
      inventory:   probe_capability(:inventory,   &check_inventory_parse/1, state),
      facts:       probe_capability(:facts,       &check_setup_self/1, state),
      execution:   probe_capability(:execution,   &check_executables/1, state),
      variable_resolution: probe_capability(:variable_resolution, &check_project_dir/1, state)
    }
  }
end

defp check_executables(state) do
  case Ansible.CLI.version(state.config) do
    {:ok, version} ->
      if Version.match?(version, ">= #{state.config.min_ansible_version}") do
        {:healthy, "ansible #{version}"}
      else
        {:unhealthy, "ansible #{version} below minimum #{state.config.min_ansible_version}"}
      end

    {:error, :enoent} -> {:unhealthy, "ansible executable not found"}
    {:error, reason}  -> {:unhealthy, "ansible --version failed: #{inspect(reason)}"}
  end
end
```

`check_inventory_parse/1` runs `ansible-inventory --list` with a 10-second timeout and reports `:degraded` on parse warnings, `:unhealthy` on parse failure. `check_setup_self/1` runs `ansible localhost -m setup -c local` as a self-test — it does not require a connectable remote target.

Per-capability statuses feed the four-state aggregation and flapping detection from design/05 §5.6.1.

## 14.6 Configuration schema

The plugin's `config_schema/0` declares fields matching PRD §8.3.10:

```elixir
%Vigil.Plugin.Schema{
  fields: [
    %Field{name: "project_dir", type: :directory_path, required: true,
           validators: [&must_exist/1, &must_contain_inventory/1]},
    %Field{name: "ansible_executable", type: :executable_path, required: false,
           default: "ansible"},
    %Field{name: "ansible_playbook_executable", type: :executable_path, required: false,
           default: "ansible-playbook"},
    %Field{name: "ansible_galaxy_executable", type: :executable_path, required: false,
           default: "ansible-galaxy"},
    %Field{name: "inventory", type: :path, required: false},
    %Field{name: "vault_password_file", type: :path_or_secret_ref, required: false, secret?: true,
           conditional_on: %{vault_password_command: nil}},
    %Field{name: "vault_password_command", type: :string, required: false, secret?: true,
           conditional_on: %{vault_password_file: nil}},
    %Field{name: "become_user",   type: :string, required: false},
    %Field{name: "become_method", type: :string, required: false},
    %Field{name: "forks",         type: :pos_integer, required: false, default: 5},
    %Field{name: "fact_cache_backend", type: :map, required: false},
    %Field{name: "timeout.wall_clock", type: :duration, required: false, default: 3_600_000},
    %Field{name: "timeout.idle",       type: :duration, required: false, default: 300_000},
    %Field{name: "cache_ttl.inventory", type: :duration, required: false, default: 900_000},
    %Field{name: "cache_ttl.facts",     type: :duration, required: false, default: 3_600_000},
    %Field{name: "cache_ttl.variables", type: :duration, required: false, default: 900_000},
    %Field{name: "circuit_breaker.max_failures", type: :pos_integer, required: false, default: 5},
    %Field{name: "min_ansible_version", type: :version, required: false, default: "2.14.0"}
  ]
}
```

`ANS-1102` test-connection: the settings UI's "test connection" action runs three probes in sequence (executables, inventory parse, localhost setup) and reports each independently.

## 14.7 RBAC permissions

`ANS-901`..`ANS-910`: the plugin contributes eight distinct permission names. They are seeded into `role_permissions` by the migration that installs the integration's plugin record:

| Permission | Allows |
|------------|--------|
| `ansible:inventory:read` | List nodes, browse groups, see role/collection inventory |
| `ansible:facts:read` | Read gathered facts via Facts tab and dispatcher API |
| `ansible:variables:read` | `variable_lookup` (per-node) and `variable_explorer` (global) supplementary capabilities |
| `ansible:command:execute` | Run ad-hoc commands (`ansible -m shell|command|raw`) |
| `ansible:playbook:execute` | Run playbooks; subject to per-playbook allowlist via `EXEC-302` glob patterns |
| `ansible:package:manage` | Run the package module workflow |
| `ansible:cache:flush` | Trigger cache flush actions |
| `ansible:variable:decrypt` | Decrypt-on-demand of vault values when `vault_password_*` is configured (separate from `variables:read` because decryption is a more sensitive operation than viewing redacted entries) |

`ANS-909` per-playbook restriction: a role's `command_policy` for `ansible:playbook:execute` carries an allowlist of playbook paths (relative to `project_dir`). The same glob grammar from design/08 §8.3.3 applies — `deploys/*.yml` permits anything in the `deploys/` directory, `deploys/staging-*.yml` restricts to staging playbooks, an empty allowlist is "open."

## 14.8 Performance at scale

`ANS-801` target: 5,000 hosts. The bottlenecks and their mitigations:

| Bottleneck | Mitigation |
|------------|------------|
| `ansible-inventory --list` JSON size (5,000 hosts ≈ 30 MB) | Stream-parse via `Jaxon` (§14.2.2) — never load full doc |
| Concurrent setup invocations exhausting host resources | Per-integration concurrency limiter + Ansible's own `--forks` ceiling — the `forks` config is also the upper bound the `Vigil.Core.Executions.ConcurrencyGate` allows |
| Variable resolver cold-start cost | The static parse on cache miss is bounded by `host_vars/` + `group_vars/` file count; project watcher invalidates incrementally on file change rather than full reparse |
| Inventory linker pressure | The plugin emits observations in batches of 500; the Linker processes each batch as one mailbox message keeping index latency bounded |

`ANS-805`: the `forks` ceiling and the per-integration concurrency limit are configured independently. Concretely, with `forks: 25` and `concurrency: 4`, the platform allows at most 4 concurrent invocations and each invocation runs at most 25 parallel SSH connections — total parallel SSH ≤ 100. The dispatch code enforces both before invoking the runner.

## 14.9 Journal contributions

`ANS-1001`..`ANS-1003`: each execution row written by the Stream GenServer (design/06 §6.2.7) produces one journal entry per target node. The Ansible plugin's journal entry shape:

```elixir
%{
  occurred_at: ended_at,
  entry_type: "ansible.execution",
  severity: severity_from_outcome(outcome),
  summary: "#{artifact_label} on #{target.hostname}: #{outcome}",
  detail: %{
    play_recap: target.metadata.play_recap,   # ok/changed/failed/skipped/unreachable
    artifact: artifact_label,
    duration_ms: target.duration_ms,
    integration_id: integration_id
  },
  references: %{execution_id: target.id, execution_group_id: target.execution_group_id}
}
```

`ANS-1003` fact-gather entries: when a user explicitly triggers fact gathering through the LiveView (as opposed to a cache miss filling the cache), the Facts capability writes a one-off journal entry per target noting the refresh. Background fact-cache reads do **not** generate journal entries — they would flood the journal with no operational value.

## 14.10 Acceptance criteria alignment

PRD `ANS-13` (acceptance criteria) maps onto this design as follows:

| PRD criterion | Realized by |
|---------------|-------------|
| 1. Static & dynamic inventories | §14.2.2 stream parser; `ansible-inventory --list` covers both |
| 2. Linking confidence | §14.2.2 `identity_confidence/0` declaration |
| 3. Facts on demand + cache + staleness | §14.3.2 dual-mode (live + cache backend) with freshness tags |
| 4. Variable resolution with precedence + vault redaction | §14.2.3 + `redact_vault/1` |
| 5. Cross-inventory variable search | `VariableResolver.search/2` powering the `variable_explorer` supplementary capability |
| 6. Ad-hoc execution with streaming | §14.3.4 runner + Stream GenServer integration |
| 7. Playbook execution + tags + check + diff + structured output | §14.3.4 JSON callback parsing |
| 8. PLAY RECAP as structured metadata | `play_recap` stamped into `executions.metadata` per row |
| 9. Package management | §14.3.4 package module wrapper |
| 10. Timeouts | Shared `CLIRunner` enforces wall-clock + idle |
| 11. Concurrency + forks ceiling | §14.8 dual-limit model |
| 12. RBAC | §14.7 eight permissions |
| 13. Per-target outcomes on partial failure | Worst-event-seen state machine in the runner |
| 14. Journal entries per execution | §14.9 |
| 15. Health checks for executables / inventory / version | §14.5 |

---

[← Previous: Puppet Integration](11-puppet-integration.md) | [Next: Proxmox Integration →](15-proxmox-integration.md)

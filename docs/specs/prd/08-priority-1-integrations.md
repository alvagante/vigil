# 8. Priority 1 Integrations — Bolt, Ansible, SSH

These three integrations complete the Phase 1 stack alongside Puppet. Where Puppet is the deepest *visibility* integration, Bolt, Ansible, and SSH are Vigil's first **execution-capable** integrations. They share a common operational pattern: Vigil invokes a CLI tool (or establishes a direct SSH session) on the host machine, with the privileges of the system user the application runs as.

## 8.1 The CLI-invocation model

All three integrations share an operating principle that the system **MUST** uphold:

> **Vigil does on your infrastructure what you can do from the machine it runs on, with the permissions of the user it runs as.**

| ID | Requirement |
|----|-------------|
| `EXEC-CLI-001` | CLI-based integrations **MUST** invoke the underlying tool (e.g., `bolt`, `ansible-playbook`, `ssh`) as the system user running Vigil. The platform **MUST NOT** require the integrations to run with elevated privileges. |
| `EXEC-CLI-002` | CLI-based integrations **MUST** rely on the host's existing tool installation, configuration, credentials, and network access. Vigil **MUST NOT** duplicate or override the tool's standard configuration discovery. |
| `EXEC-CLI-003` | CLI-based integrations **MUST NOT** require an agent on target nodes. The agentless model is mandatory for these three integrations. |
| `EXEC-CLI-004` | CLI-based integrations **MUST** apply platform RBAC and command security controls *before* invoking the underlying tool, not as a property of the tool's own controls. |
| `EXEC-CLI-005` | CLI-based integrations **MUST** capture stdout, stderr, exit status, and full duration of every invocation. |
| `EXEC-CLI-006` | CLI-based integrations **MUST** apply both wall-clock and idle timeouts to every invocation, configurable per-integration and per-command. The platform **MUST** terminate processes that exceed either threshold. |

## 8.2 Bolt

Bolt is Puppet's agentless orchestrator. It runs commands, scripts, tasks, and plans against nodes defined in its own inventory format — **independent of PuppetDB**. The Bolt integration is therefore distinct from the Puppet integration and **MUST** be configured separately.

### 8.2.1 Capabilities provided

Per the [integration matrix](05-integration-matrix.md), Bolt provides Inventory and Remote Execution.

### 8.2.2 Inventory

| ID | Requirement |
|----|-------------|
| `BOLT-101` | The Bolt plugin **MUST** parse Bolt inventory files (`inventory.yaml`) located in the configured Bolt project directory. |
| `BOLT-102` | The plugin **MUST** preserve the inventory's group structure, including nested groups. |
| `BOLT-103` | The plugin **MUST** preserve transport configuration per node and per group: SSH, WinRM, Docker, local, and any custom transport declared. |
| `BOLT-104` | The plugin **MUST** display per-node connection parameters (user, port, transport-specific options) in the node detail view, with secrets redacted. |
| `BOLT-105` | The plugin **MUST** support multiple Bolt project directories configured as separate integrations, each yielding its own inventory namespace. |
| `BOLT-106` | The plugin **MUST** support inventory plugins / dynamic inventory references in `inventory.yaml` where Bolt itself supports them. |

### 8.2.3 Remote execution

| ID | Requirement |
|----|-------------|
| `BOLT-201` | The Bolt plugin **MUST** support ad-hoc shell command execution on selected target nodes. |
| `BOLT-202` | The Bolt plugin **MUST** support Puppet task execution. The plugin **MUST** discover available tasks (`bolt task show`) including task metadata: description, parameters with type and required-flag. |
| `BOLT-203` | Task parameter input forms **MUST** be auto-generated from task metadata. The plugin **MUST** validate parameter types client-side before submission. |
| `BOLT-204` | The Bolt plugin **MUST** support plan execution. The plugin **MUST** discover available plans (`bolt plan show`) with metadata: description, parameters, expected outcome. |
| `BOLT-205` | The Bolt plugin **MUST** stream output (stdout, stderr) per target node in real time, with target attribution. |
| `BOLT-206` | The Bolt plugin **MUST** preserve the full transcript of every execution, retrievable via the execution history. |
| `BOLT-207` | The Bolt plugin **MUST** support package management as a built-in capability: install, remove, update for `apt`, `yum`, `dnf`, `zypper` package families. The plugin **MAY** implement this via standard Puppet/Bolt tasks (e.g., `package`) rather than custom code. |

### 8.2.4 Configuration schema

| Field | Required | Description |
|-------|----------|-------------|
| `project_dir` | yes | Path to the Bolt project directory |
| `bolt_executable` | no | Path to `bolt` binary (default: `bolt` from PATH) |
| `inventory_file` | no | Override inventory file path (default: project's `inventory.yaml`) |
| `default_transport` | no | Default transport when not specified per-node |
| `concurrency` | no | Per-execution concurrent target limit |
| `timeout.wall_clock` | no | Default wall-clock timeout per invocation |
| `timeout.idle` | no | Default idle timeout per invocation |

### 8.2.5 Resilience

| ID | Requirement |
|----|-------------|
| `BOLT-301` | The Bolt plugin **MUST** apply wall-clock and idle timeouts to every CLI invocation. Defaults: wall-clock 1 hour, idle 5 minutes. Both **MUST** be overridable per command. |
| `BOLT-302` | If the Bolt CLI exits abnormally (signal, crash, missing executable), the plugin **MUST** report a structured error and **MUST NOT** corrupt the execution record. |
| `BOLT-303` | The plugin **MUST** apply per-integration concurrent-execution limits. Excess invocations **MUST** queue or fail-fast based on configuration. |

### 8.2.6 RBAC

| ID | Requirement |
|----|-------------|
| `BOLT-401` | The Bolt plugin **MUST** define the following permissions: `bolt:inventory:read`, `bolt:command:execute`, `bolt:task:execute`, `bolt:plan:execute`, `bolt:package:manage`. |
| `BOLT-402` | Granular execution permissions (per-command, per-task, per-plan) **MUST** be enforceable as defined in [section 11.5](11-platform-requirements.md). |

### 8.2.7 Journal contributions

| ID | Requirement |
|----|-------------|
| `BOLT-501` | Each execution **MUST** generate one journal entry per target node, summarizing: command/task/plan name, exit status, duration, initiating user. The entry **MUST** link to the full transcript. |

## 8.3 Ansible

Ansible is the agentless configuration management and orchestration tool. The Ansible integration provides Inventory, Facts, and Remote Execution. Unlike Puppet, Ansible is stateless — it produces no persistent server-side store of facts or run history. Vigil compensates by maintaining its own cache of gathered facts and execution transcripts.

The Ansible integration operates against a configured **Ansible project directory**: a directory containing an inventory source and playbooks. Multiple independent Ansible projects may be configured as separate integrations.

### 8.3.1 Capabilities provided

| Capability | Surface |
|------------|---------|
| Inventory | Nodes from Ansible inventory (static INI/YAML or dynamic) |
| Facts | System facts gathered on-demand via the `setup` module |
| Remote Execution | Ad-hoc commands, playbook execution, package management |

The plugin **MUST NOT** declare Monitoring, Configuration, Events, Provisioning, or Deployment capabilities.

#### Supplementary capabilities

In addition to its generic integration types, the Ansible plugin declares the following supplementary capabilities (see [section 6.7](06-plugin-architecture.md#67-supplementary-capabilities-and-ui-extension-slots)):

| Capability ID | Slot | Description |
|---------------|------|-------------|
| `ansible:variable_lookup` | `node_tab` | Per-node variable resolution: all variables effective for this node, their values, and the precedence layer that provided each one |
| `ansible:variable_explorer` | `global_page` | Cross-inventory variable browser: search for a variable by name across all hosts and groups, see where it is defined and how it resolves per host |
| `ansible:role_browser` | `global_page` | Browse installed roles and Galaxy collections in the project: role entry points, task lists, role defaults and vars |
| `ansible:playbook_history` | `global_page` | Cross-node playbook execution history with per-node success/failure trend, last execution time, and link to each transcript |

Each supplementary capability is independently RBAC-gated and hidden entirely when the user lacks the required permission (`PLUG-806`).

### 8.3.2 Inventory

| ID | Requirement |
|----|-------------|
| `ANS-101` | The Ansible plugin **MUST** parse Ansible inventory in both static formats (INI, YAML) and dynamic formats (script-based or plugin-based dynamic inventory), invoking `ansible-inventory --list` for dynamic sources. |
| `ANS-102` | The plugin **MUST** preserve group hierarchy including nested groups and the special `all` and `ungrouped` groups, presenting them as Vigil groups. |
| `ANS-103` | The plugin **MUST** preserve host variables and group variables, making them available in the variable resolution view (`ANS-301`). Sensitive-looking values **MUST** be redacted when rendered in the UI. |
| `ANS-104` | The plugin **MUST** support multiple Ansible projects as separate integrations, each with its own inventory namespace. |
| `ANS-105` | The plugin **MUST** report nodes' connection-relevant metadata: connection user, port, become method, Ansible connection plugin where explicitly set. |
| `ANS-106` | The plugin **MUST** declare its linking confidence as: `ansible_host` (if set and is a resolvable hostname or IP) is the primary linking candidate; the inventory hostname alias is treated as best-effort. The plugin **MUST** declare this confidence level to the platform so the linking engine can apply appropriate weight. |
| `ANS-107` | When `ansible-inventory --list` returns an error (invalid inventory, missing dependencies), the plugin **MUST** report the error as an integration-level health issue and **MUST NOT** serve a partial or stale inventory without a staleness marker. |
| `ANS-108` | The plugin **MUST** support scheduled inventory refresh at a configurable interval (default: 15 minutes) and expose an on-demand refresh action (`PLUG-013`). |

### 8.3.3 Facts

| ID | Requirement |
|----|-------------|
| `ANS-201` | The Ansible plugin **MUST** gather facts via `ansible <target> -m setup` on demand, against targets specified by the user. |
| `ANS-202` | The plugin **MUST NOT** automatically gather facts against all inventory hosts on schedule unless explicitly configured to do so. Default behavior is on-demand fact gathering per node. |
| `ANS-203` | Gathered facts **MUST** be cached per node with TTL configurable per integration (default: 1 hour). Cached facts **MUST** be served with the timestamp of when they were gathered. |
| `ANS-204` | The plugin **MUST** support reading from Ansible's own fact cache backends (jsonfile, redis, and others supported by the installed Ansible version) when the user has configured one, using those pre-gathered facts instead of issuing a live `setup` call. Facts sourced from Ansible's cache **MUST** be declared with their own staleness semantics, distinct from Vigil's cache TTL. |
| `ANS-205` | The plugin **MUST** declare itself authoritative for the `ansible_*` fact namespace. Facts outside that namespace reported by Ansible (custom facts from `facts.d` directories) are declared opportunistic. |
| `ANS-206` | The plugin **MUST** support custom fact directories (`/etc/ansible/facts.d` and any path configured via `ansible_facts_dir`) and **MUST** include their output in gathered facts. |
| `ANS-207` | Fact gathering failures against individual nodes (connectivity error, auth failure, timeout) **MUST** be reported per-node and **MUST NOT** abort fact gathering for other nodes in a batch request. |
| `ANS-208` | The plugin **MUST** expose a minimum set of normalized facts mapped to the platform's common fact schema: OS distribution and version, kernel, hostname, FQDN, IP addresses, CPU count, total memory — derived from standard `ansible_*` fact names. |

### 8.3.4 Variable resolution

Ansible's variable precedence system is one of its most operationally significant features. A variable's effective value for a given host depends on its source: extra_vars, set_facts, role vars, playbook vars, host_vars, group_vars, role defaults, and others — each with a distinct precedence level. Vigil makes this resolution visible without requiring the user to run a playbook to find out what a variable will be.

**Source.** Variable resolution is performed against a local parsing of the project's `host_vars/` and `group_vars/` directories and by invoking `ansible-inventory --host <hostname>`. It does not require any network access to the target node. Encrypted values (`!vault`) are detected and redacted — their plaintext is never exposed through Vigil.

| ID | Requirement |
|----|-------------|
| `ANS-301` | The Ansible plugin **MUST** support per-node variable resolution: given a node, display all variables effective for that node with their current values and the source that set each one (host_vars, group_vars for a specific group, inventory-level group_vars, role defaults). |
| `ANS-302` | The plugin **MUST** display the variable precedence chain per variable: every source that defines it, in precedence order, with the winning value highlighted. |
| `ANS-303` | Variables declared in `host_vars/` and `group_vars/` **MUST** be read from the configured project directory. The plugin reads only — it **MUST NOT** modify project files. |
| `ANS-304` | Ansible Vault-encrypted values **MUST** be detected and displayed as `[encrypted]`. The plugin **MUST NOT** expose plaintext vault values in the UI. If a vault password file or command is configured, the plugin **MAY** offer a decrypt-on-demand action, but **MUST** handle decryption errors gracefully. |
| `ANS-305` | The plugin **MUST** support cross-inventory variable search: given a variable name, return all hosts and groups where that variable is defined, with the value at each definition site. This powers the `ansible:variable_explorer` supplementary capability. |
| `ANS-306` | Magic variables (`inventory_hostname`, `groups`, `hostvars`, `ansible_play_hosts`) **MUST** be recognized and labeled as computed/runtime-only in the UI — they are not parsed from static files. |
| `ANS-307` | Variable resolution **MUST** be scoped to the configured project. Variables from a different Ansible integration instance **MUST NOT** bleed across. |

### 8.3.5 Remote execution

| ID | Requirement |
|----|-------------|
| `ANS-401` | The Ansible plugin **MUST** support ad-hoc command execution via `ansible -m shell` (or `command`/`raw` per user choice) against selected target nodes. |
| `ANS-402` | The plugin **MUST** support playbook execution via `ansible-playbook` with extra-vars passed as user input. |
| `ANS-403` | The plugin **MUST** discover available playbooks within the configured project directory (by enumeration of `*.yml` and `*.yaml` files at the top level and one level deep) and present them to the user. |
| `ANS-404` | For each discovered playbook, the plugin **SHOULD** extract declared metadata where parseable: play names, task counts, and any `vars_prompt` declarations (to pre-generate parameter input forms). |
| `ANS-405` | The plugin **MUST** support the following playbook execution options as UI-exposed parameters: extra-vars (key-value pairs), tags (`--tags`), skip-tags (`--skip-tags`), check mode (`--check`), diff mode (`--diff`), verbosity level. |
| `ANS-406` | The plugin **MUST** stream stdout and stderr output in real time, with per-target attribution where the structured output format allows extraction. |
| `ANS-407` | The plugin **MUST** use structured playbook output (via JSON callback or equivalent) to present results in a structured format: per-play, per-task, per-host result, with status (ok, changed, failed, skipped, unreachable). The raw text transcript **MUST** also be preserved in full. |
| `ANS-408` | The plugin **MUST** preserve the full transcript of every execution, retrievable via execution history. |
| `ANS-409` | The plugin **MUST** surface the Ansible PLAY RECAP summary — per-host ok/changed/failed/skipped/unreachable counts — as structured metadata on the execution record, not only in the raw transcript. |
| `ANS-410` | The plugin **MUST** support package management as a built-in capability via the Ansible `package` module: install, remove, update across `apt`, `yum`, `dnf`, `zypper`. |
| `ANS-411` | The plugin **MUST** discover installed Galaxy roles and collections in the project (`ansible-galaxy list`) and make them available for execution workflows. |
| `ANS-412` | When an execution fails against some but not all targets, the plugin **MUST** report per-target outcomes: succeeded nodes, failed nodes, unreachable nodes. The overall execution status **MUST** reflect the worst-case result. |

### 8.3.6 Authentication and transport

| ID | Requirement |
|----|-------------|
| `ANS-501` | The Ansible plugin **MUST** rely on Ansible's standard connection configuration hierarchy: `ansible.cfg`, inventory variables (`ansible_user`, `ansible_ssh_private_key_file`, `ansible_become`, etc.), and host/group_vars. Vigil **MUST NOT** override or duplicate Ansible's connection model. |
| `ANS-502` | The plugin **MUST** support SSH key authentication via key files referenced in inventory or configuration. Key file paths **MUST** be treated as secrets-adjacent and **MUST NOT** be logged. |
| `ANS-503` | The plugin **MUST** support Ansible Vault integration: a vault password file or vault password command **MAY** be provided in integration configuration. The vault credential **MUST** be handled through the platform's secrets-aware mechanism (`PLUG-204`). |
| `ANS-504` | The plugin **MUST** support `become` execution as configured in inventory or `ansible.cfg`. The become method and become user **MUST** be configurable per integration as a default, overridable by inventory settings. |
| `ANS-505` | Ansible connection plugins beyond SSH (e.g., `docker`, `kubectl`, `local`, `winrm`) **MUST** be usable if installed and configured in inventory. The plugin defers to Ansible's own connection plugin discovery — Vigil does not enumerate them. |
| `ANS-506` | WinRM transport for Windows targets **MUST** be usable when configured in inventory (via `ansible_connection: winrm`). Vigil passes through Ansible's WinRM configuration without special handling. |
| `ANS-507` | The plugin **MUST NOT** disable host-key verification by default. When host key checking is disabled in `ansible.cfg` or inventory, the plugin **MUST** surface this as a warning in the integration administration UI. |

### 8.3.7 Resilience

| ID | Requirement |
|----|-------------|
| `ANS-601` | The Ansible plugin **MUST** apply wall-clock and idle timeouts to all CLI invocations. Defaults: wall-clock 1 hour, idle 5 minutes. Both **MUST** be overridable per integration and per execution. |
| `ANS-602` | The plugin **MUST** detect inventory source failures (non-zero exit from `ansible-inventory`) and report them as integration-level health issues, not per-execution failures. |
| `ANS-603` | The plugin **MUST** apply per-integration concurrent-execution limits. Excess invocations **MUST** queue or reject based on configuration. |
| `ANS-604` | If the `ansible` or `ansible-playbook` executable is missing or returns an unexpected version, the plugin **MUST** report this as an initialization failure and mark the integration unhealthy. |
| `ANS-605` | The plugin **MUST** detect and report the Ansible version at initialization time. The minimum supported Ansible version **MUST** be declared in the plugin manifest. |
| `ANS-606` | Execution failures against individual nodes (unreachable, auth failure, task failure) **MUST** be reported per-node and **MUST NOT** prevent other nodes' results from being captured. |

### 8.3.8 Caching

| ID | Requirement |
|----|-------------|
| `ANS-701` | Cache TTL defaults: inventory 15 minutes, facts 1 hour, variable resolution 15 minutes. All **MUST** be overridable per integration. |
| `ANS-702` | The plugin **MUST** expose an on-demand cache flush action per capability (inventory only, facts only, variables only, all) and globally (`PLUG-013`). Cache flush **MUST** be RBAC-gated (see `ANS-908`). |
| `ANS-703` | When Ansible's own fact cache backend is configured as the facts source (`ANS-204`), the cache TTL **MUST** reflect the backend's own expiry setting, and the plugin **MUST** respect it rather than imposing its own TTL on top. |
| `ANS-704` | Variable resolution results (from static file parsing) **MUST** be invalidated when the project's `host_vars/` or `group_vars/` files change. The plugin **SHOULD** detect modification via filesystem timestamps on each inventory refresh cycle. |

### 8.3.9 Performance at scale

| ID | Requirement |
|----|-------------|
| `ANS-801` | The Ansible plugin **MUST** handle inventories of 5,000 nodes without functional degradation. |
| `ANS-802` | Inventory parsing and fact gathering **MUST** be performed asynchronously; the UI **MUST NOT** block on inventory refresh. |
| `ANS-803` | Fact gathering against large node sets **MUST** be batched: the plugin **MUST** invoke Ansible with controlled parallelism (via `--forks`) rather than spawning unbounded concurrent processes. |
| `ANS-804` | The `ansible-inventory --list` output for large inventories may be substantial. The plugin **MUST** parse it without holding the entire JSON representation in memory longer than necessary. |
| `ANS-805` | Concurrent playbook executions are limited by `ANS-603`. The plugin **MUST** apply a per-integration forks ceiling so that concurrent executions do not collectively exhaust the host's resources. |

### 8.3.10 Configuration schema

| Field | Required | Description |
|-------|----------|-------------|
| `project_dir` | yes | Path to the Ansible project directory containing inventory and playbooks |
| `ansible_executable` | no | Path to `ansible` binary (default: `ansible` from PATH) |
| `ansible_playbook_executable` | no | Path to `ansible-playbook` binary (default: `ansible-playbook` from PATH) |
| `ansible_galaxy_executable` | no | Path to `ansible-galaxy` binary (default: `ansible-galaxy` from PATH) |
| `inventory` | no | Path to inventory file or dynamic inventory script; defaults to project dir's detected inventory |
| `vault_password_file` | no | Path to vault password file (handled as secret; mutually exclusive with `vault_password_command`) |
| `vault_password_command` | no | Command that outputs the vault password on stdout (handled as secret) |
| `become_user` | no | Default become user for executions |
| `become_method` | no | Default become method (`sudo`, `su`, etc.) |
| `forks` | no | Default `--forks` value for executions (default: Ansible's own default) |
| `fact_cache_backend` | no | When set, use Ansible's fact cache at this backend path/URL instead of live `setup` calls |
| `timeout.wall_clock` | no | Default wall-clock timeout per invocation |
| `timeout.idle` | no | Default idle timeout per invocation |
| `cache_ttl.inventory` | no | Inventory cache TTL override (default: 15 minutes) |
| `cache_ttl.facts` | no | Facts cache TTL override (default: 1 hour) |
| `cache_ttl.variables` | no | Variable resolution cache TTL override (default: 15 minutes) |
| `circuit_breaker.*` | no | Circuit breaker tuning |

| ID | Requirement |
|----|-------------|
| `ANS-1101` | The Ansible plugin **MUST** validate the configuration above at `initialize` and **MUST** reject configurations that lack a resolvable `project_dir`. |
| `ANS-1102` | The plugin **MUST** expose a "test connection" action that verifies: Ansible executables are found and meet the minimum declared version, the inventory parses without error, and a minimal connectivity probe can execute. |

### 8.3.11 RBAC integration

| ID | Requirement |
|----|-------------|
| `ANS-901` | The Ansible plugin's actions **MUST** be governed by the platform RBAC. The following distinct permissions **MUST** exist: |
| `ANS-902` | — `ansible:inventory:read` — view nodes and group membership |
| `ANS-903` | — `ansible:facts:read` — view gathered facts |
| `ANS-904` | — `ansible:variables:read` — view host and group variables, including the variable explorer supplementary capability |
| `ANS-905` | — `ansible:command:execute` — execute ad-hoc commands |
| `ANS-906` | — `ansible:playbook:execute` — execute playbooks |
| `ANS-907` | — `ansible:package:manage` — perform package management operations |
| `ANS-908` | — `ansible:cache:flush` — trigger cache flush actions |
| `ANS-909` | Granular per-playbook permissions **MUST** be enforceable: a role may be granted `ansible:playbook:execute` restricted to specific named playbooks via the platform's command allowlist mechanism (see [section 11.5](11-platform-requirements.md)). |
| `ANS-910` | `ansible:variables:read` is a distinct permission from `ansible:facts:read` because host_vars and group_vars may contain secrets or operational data the operator does not want all users to see. |

### 8.3.12 Journal contributions

| ID | Requirement |
|----|-------------|
| `ANS-1001` | Each execution **MUST** generate one journal entry per target node, summarizing: command or playbook name, exit status, duration, initiating user, and per-node PLAY RECAP counts (ok/changed/failed/unreachable) for playbook runs. The entry **MUST** link to the full transcript. |
| `ANS-1002` | Failed executions (all targets failed, or non-zero exit) **MUST** generate journal entries with clear failure indication — they **MUST NOT** be silently omitted. |
| `ANS-1003` | When a user explicitly triggers fact gathering (as opposed to background scheduling), the plugin **MUST** generate a journal entry noting that facts were refreshed, by whom, and when. |

### 8.3.13 Acceptance criteria

The Ansible integration is considered complete when:

1. Static and dynamic inventories are parsed correctly and presented in unified inventory with group hierarchy preserved.
2. Host linking confidence is correctly declared and respected by the linking engine.
3. Facts are gathered on demand per node via `setup`, cached with TTL, and served with staleness markers.
4. Variable resolution shows the full precedence chain for any variable on any node, with vault-encrypted values detected and redacted.
5. Cross-inventory variable search returns all hosts and groups where a variable is defined.
6. Ad-hoc command execution works against single and multi-node targets with real-time streaming.
7. Playbook execution works with tag filtering, check mode, and diff mode; structured per-task output is presented per-host.
8. PLAY RECAP summary is captured and shown as structured metadata on the execution record.
9. Package management operations work via the Ansible `package` module against all supported package families.
10. Wall-clock and idle timeouts terminate overdue processes.
11. Concurrent execution limits are enforced and the forks ceiling prevents resource exhaustion.
12. RBAC permissions block unauthorized executions and variable access.
13. Per-node execution outcomes (ok/changed/failed/unreachable) are captured even when a subset of targets fails.
14. Journal entries are generated for all executions with per-target detail.
15. Health checks detect missing executables, broken inventories, and Ansible version incompatibility.

## 8.4 SSH

SSH is the lowest-level execution integration. It provides Inventory (from `~/.ssh/config` or a custom path), Facts (gathered via SSH commands), and Remote Execution. SSH does not depend on any orchestrator framework.

### 8.4.1 Inventory

| ID | Requirement |
|----|-------------|
| `SSH-101` | The SSH plugin **MUST** parse SSH config files (default: `~/.ssh/config`, configurable per integration) and produce an inventory of `Host` aliases. |
| `SSH-102` | The plugin **MUST** preserve and display host-level connection parameters: hostname (resolved), port, user, identity file. |
| `SSH-103` | The plugin **MUST** support `Host` patterns and **MUST** flag wildcard hosts as non-targetable in the UI (they are configuration directives, not executable destinations). |
| `SSH-104` | The plugin **MUST** support inclusion of multiple config files (via `Include` directives) where the SSH client supports them. |
| `SSH-105` | The plugin **MUST** support multiple SSH config sources as separate integrations. |

### 8.4.2 Facts

| ID | Requirement |
|----|-------------|
| `SSH-201` | The SSH plugin **MUST** gather a baseline set of system facts via SSH commands when requested per node. The baseline **MUST** include: OS distribution and version, kernel, architecture, CPU count, memory total, network interfaces with IPs, hostname, uptime. |
| `SSH-202` | Fact gathering **MUST** use a small, well-defined set of commands (e.g., `cat /etc/os-release`, `uname -a`, `ip -j addr`) and **MUST NOT** require the target to have any special tooling installed beyond a POSIX baseline. |
| `SSH-203` | The plugin **MUST** support optional Windows fact gathering via PowerShell where the SSH transport reaches a Windows host configured to accept it. |
| `SSH-204` | Facts **MUST** be cached per node with TTL configurable (default: 1 hour). |
| `SSH-205` | The plugin **MUST** be authoritative for SSH-derived facts only and opportunistic for any fact value also reported by another source. |

### 8.4.3 Remote execution

| ID | Requirement |
|----|-------------|
| `SSH-301` | The SSH plugin **MUST** support shell command execution over SSH against any node in its inventory. |
| `SSH-302` | The plugin **MUST** maintain a connection pool to amortize SSH session-establishment cost across consecutive executions to the same host. |
| `SSH-303` | The plugin **MUST** stream stdout and stderr in real time, with per-target attribution when executing against multiple nodes. |
| `SSH-304` | The plugin **MUST** preserve the full transcript of every execution. |
| `SSH-305` | The plugin **MUST** support package management across Linux distributions: `apt`, `yum`, `dnf`, `zypper`. The plugin **MUST** detect the package manager from gathered facts (or via probing) and use the correct one. |
| `SSH-306` | The plugin **MUST** support configurable per-integration concurrent execution limits and **MUST** apply a per-target connection rate limit to avoid overwhelming target sshd processes. |

### 8.4.4 Configuration schema

| Field | Required | Description |
|-------|----------|-------------|
| `config_path` | no | Path to SSH config file (default: `~/.ssh/config`) |
| `default_user` | no | Default SSH user when not specified per host |
| `default_identity_file` | no | Default identity file when not specified |
| `connection_pool.max_per_host` | no | Connection pool size per target |
| `connection_pool.idle_ttl` | no | How long to keep idle connections open |
| `concurrency` | no | Global concurrent execution limit |
| `timeout.wall_clock` | no | Default wall-clock timeout per command |
| `timeout.idle` | no | Default idle timeout per command |
| `timeout.connect` | no | Connection establishment timeout |

### 8.4.5 Resilience

| ID | Requirement |
|----|-------------|
| `SSH-401` | The SSH plugin **MUST** apply connection, wall-clock, and idle timeouts independently. Defaults: connect 10s, wall-clock 1 hour, idle 5 minutes. |
| `SSH-402` | The plugin **MUST** detect host-key changes and surface them as actionable errors (not silently bypass key verification). |
| `SSH-403` | The plugin **MUST** support known-hosts management consistent with the host system's SSH configuration. |
| `SSH-404` | The plugin **MUST NOT** disable host-key verification by default. A "skip host key check" mode **MAY** be exposed for development with a prominent warning. |
| `SSH-405` | Connection failures (refused, timeout, auth failure) **MUST** be reported as per-target errors that do not abort an execution against other targets. |

### 8.4.6 RBAC

| ID | Requirement |
|----|-------------|
| `SSH-501` | Permissions: `ssh:inventory:read`, `ssh:facts:read`, `ssh:command:execute`, `ssh:package:manage`. |
| `SSH-502` | Per-command granular permissions **MUST** be enforceable (e.g., a role that may run `systemctl status *` but not arbitrary commands). |

### 8.4.7 Journal contributions

| ID | Requirement |
|----|-------------|
| `SSH-601` | Each execution **MUST** generate one journal entry per target node. |

## 8.5 Common acceptance criteria

The Phase 1 execution integrations are considered complete when:

1. Each plugin's inventory is correctly parsed and presented in unified inventory.
2. Each plugin's identity-linking confidence is correctly declared and respected by the linking rules.
3. Each plugin can execute a shell command and stream output to the UI in real time.
4. Each plugin's full transcript is preserved and retrievable after the stream closes.
5. Wall-clock and idle timeouts correctly terminate runaway processes.
6. Concurrency limits are enforced.
7. RBAC permissions block unauthorized executions.
8. Each execution generates the appropriate journal entries with source attribution.
9. Health checks detect missing executables, broken inventories, and stuck CLI processes.
10. The plugin contract is identical across all three (validating its generality).

---

[← Previous: Puppet Integration](07-puppet-integration.md) | [Next: Proxmox, AWS, Azure →](09-priority-1b-integrations.md)

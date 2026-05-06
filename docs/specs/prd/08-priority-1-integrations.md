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

Ansible is the agentless configuration management and orchestration tool. The Ansible integration provides Inventory, Facts, and Remote Execution.

### 8.3.1 Inventory

| ID | Requirement |
|----|-------------|
| `ANS-101` | The Ansible plugin **MUST** parse Ansible inventory in both static formats (INI, YAML) and dynamic formats (script-based or plugin-based dynamic inventory), invoking `ansible-inventory` or equivalent introspection where dynamic. |
| `ANS-102` | The plugin **MUST** preserve group hierarchy including nested groups and the special `all` and `ungrouped` groups. |
| `ANS-103` | The plugin **MUST** preserve host variables and group variables, displaying them in the node detail view with secrets redacted. |
| `ANS-104` | The plugin **MUST** support multiple Ansible projects as separate integrations, each with its own inventory namespace. |
| `ANS-105` | The plugin **MUST** report nodes' connection-relevant metadata: user, port, become method, ansible connection plugin where set. |

### 8.3.2 Facts

| ID | Requirement |
|----|-------------|
| `ANS-201` | The Ansible plugin **MUST** gather facts via `ansible -m setup` on demand, against the targets specified by the user. |
| `ANS-202` | The plugin **MUST NOT** automatically gather facts against all inventory hosts on schedule unless explicitly configured to do so. Default behavior is on-demand fact gathering. |
| `ANS-203` | Gathered facts **MUST** be cached per node with TTL configurable per integration (default: 1 hour). |
| `ANS-204` | The plugin **MUST** support optional fact caching against Ansible's own fact cache backends where the user has configured one. |
| `ANS-205` | The plugin **MUST** declare itself authoritative for the `ansible_*` fact namespace and opportunistic for everything else. |

### 8.3.3 Remote execution

| ID | Requirement |
|----|-------------|
| `ANS-301` | The Ansible plugin **MUST** support ad-hoc command execution via `ansible -m shell` (or `command`/`raw` per user choice) against selected target nodes. |
| `ANS-302` | The plugin **MUST** support playbook execution via `ansible-playbook` with extra-vars passed as user input. |
| `ANS-303` | The plugin **MUST** discover available playbooks within the configured project directory and present them with their declared parameter expectations (where parseable). |
| `ANS-304` | The plugin **MUST** stream output (stdout, stderr) in real time, with per-target attribution where Ansible's output formatting allows extraction. The plugin **MAY** use Ansible callback plugins to enable structured streaming output. |
| `ANS-305` | The plugin **MUST** preserve the full transcript of every execution. |
| `ANS-306` | The plugin **MUST** support package management as a built-in capability via the Ansible `package` module: install, remove, update across `apt`, `yum`, `dnf`, `zypper`. |

### 8.3.4 Configuration schema

| Field | Required | Description |
|-------|----------|-------------|
| `project_dir` | yes | Path to the Ansible project directory |
| `ansible_executable` | no | Path to `ansible` binary |
| `ansible_playbook_executable` | no | Path to `ansible-playbook` binary |
| `inventory` | no | Inventory path or dynamic inventory script |
| `vault_password_file` | no | Path to vault password file (handled as secret) |
| `become_user` | no | Default become user for executions |
| `concurrency` | no | Default `--forks` value |
| `timeout.wall_clock` | no | Default wall-clock timeout |
| `timeout.idle` | no | Default idle timeout |

### 8.3.5 Resilience

| ID | Requirement |
|----|-------------|
| `ANS-401` | The Ansible plugin **MUST** apply wall-clock and idle timeouts. Defaults: wall-clock 1 hour, idle 5 minutes. |
| `ANS-402` | The plugin **MUST** detect Ansible inventory script failures and report them as plugin-level health issues, not as per-execution failures. |
| `ANS-403` | The plugin **MUST** apply per-integration concurrent-execution limits. |

### 8.3.6 RBAC

| ID | Requirement |
|----|-------------|
| `ANS-501` | Permissions: `ansible:inventory:read`, `ansible:facts:read`, `ansible:command:execute`, `ansible:playbook:execute`, `ansible:package:manage`. |
| `ANS-502` | Granular per-playbook permissions **MUST** be enforceable. |

### 8.3.7 Journal contributions

| ID | Requirement |
|----|-------------|
| `ANS-601` | Each execution **MUST** generate one journal entry per target node. |

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

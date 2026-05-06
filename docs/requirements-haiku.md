# Prompt: Generate Requirements & Specifications Document for Vigil

Use this prompt as input for an AI assistant to produce a clean, implementation-agnostic requirements and specifications document for Vigil — designed from scratch without reference to any existing codebase.

---

# Vigil — Where your infrastructure tools converge.

I need you to produce a comprehensive **Product Requirements & Specifications Document** for a product called **Vigil**.

Vigil is a **web-based command-and-control interface for infrastructure management**. It provides a unified frontend for inventory browsing, remote execution, configuration inspection, provisioning, monitoring visibility, event tracking, and operations management across heterogeneous infrastructure tooling.

**Target users**: Infrastructure engineers and DevOps teams managing physical servers, VMs, and cloud instances using a mix of configuration management, provisioning, monitoring, security, and remote execution tools.

**Scale**: Vigil must support large installations with several thousands of managed nodes. All design decisions around data fetching, caching, pagination, and API interaction must account for this scale. The system must avoid flooding upstream tool APIs and the interface must remain responsive under load.

---

## Integration Types

The system defines **9 integration types** representing fundamentally different interaction patterns with external tools:

| # | Type | Core Question | What It Provides |
|---|------|---------------|-----------------|
| 1 | **Inventory** | Who exists? | Node identity, status, grouping |
| 2 | **Facts** | What IS this node? | Observed attributes (OS, hardware, network, packages) |
| 3 | **Configuration** | What SHOULD this node be? | Desired state, policy data, parameters |
| 4 | **Events** | What changed? | Discrete state transitions, grouped by run/report when applicable |
| 5 | **Monitoring** | Is it healthy right now? | Current check status, metrics, alerts |
| 6 | **Reports** | How did a run go? | Structured execution/scan results with metrics and logs |
| 7 | **Remote Execution** | Do something on it | Commands, tasks, playbooks — with streaming output |
| 8 | **Provisioning** | Create/destroy/lifecycle | VM/container management, resource discovery |
| 9 | **Deployment** | What's running on it? | App versions, deploy history (read-only visibility) |

### Integration Type Definitions

- **Inventory**: Provide a list of managed nodes (servers, VMs, containers) with identity, status, and grouping. Nodes from multiple sources are linked by identity (hostname, certname, IP, FQDN) into a unified inventory with source attribution. Must handle deduplication across sources.

- **Facts**: Provide observed, point-in-time attributes of a node — OS, hardware specs, network interfaces, installed packages, uptime. Facts are descriptive ("what IS") and cacheable. Different sources may provide overlapping or complementary facts.

- **Configuration**: Provide desired-state or policy data — what a node SHOULD be. Includes hierarchical configuration data, compiled catalogs, resource declarations, class parameters, variables. Configuration is prescriptive and typically version-controlled.

- **Events**: Provide discrete state transitions — something changed on a node. Events are grouped by their originating run/report when applicable (e.g., a Puppet run that changes 3 resources produces 3 events grouped under one report). Events with no actual changes (no-op runs) are not surfaced in the journal.

- **Monitoring**: Provide current health status of a node — check results, service states, metric values, active alerts. Monitoring data has short TTL and may be live-updating. State CHANGES from monitoring (OK→CRITICAL) also generate Events.

- **Reports**: Provide structured results of a completed run or scan — metrics, logs, resource-level details, success/failure counts. Reports are richer than individual events; they represent a complete execution with summary statistics and drill-down capability.

- **Remote Execution**: Execute commands, tasks, scripts, or playbooks on target nodes. Supports real-time streaming output (stdout/stderr), execution history with full output preservation, re-execution of previous commands, concurrent execution limits, and command security controls.

- **Provisioning**: Create, destroy, and manage lifecycle of virtual machines or containers (start, stop, reboot, suspend, resume, deallocate). Includes resource discovery (available images, sizes/flavors, networks, storage, regions).

- **Deployment**: Provide read-only visibility into application deployments on nodes — what version of what application was deployed when, by whom, with what result. Vigil does not manage deployments; it observes them from external tools.

---

## Journal Behavior by Integration Type

The Node Journal is a per-node timeline of significant events. How each integration type feeds the journal:

| Type | Journal Behavior |
|------|-----------------|
| Events | Written directly — each state change is a journal entry |
| Reports | Events extracted from reports are written (grouped by report). No-change runs are silent. |
| Provisioning | Lifecycle actions (create, destroy, start, stop) generate journal entries |
| Remote Execution | Each execution generates a journal entry |
| Deployment | Each deploy event generates a journal entry |
| Monitoring | State CHANGES only (OK→CRITICAL, CRITICAL→OK) generate journal entries. Steady-state is silent. |
| Facts / Configuration / Inventory | Do not generate journal entries (reference data, not events) |

---

## Integrations — Priority 1 (Core, implement first)

These integrations define the initial product scope (Phase 1):
- **Puppet, Bolt, Ansible, SSH** — the minimum viable product
- **Proxmox, AWS, Azure** — Phase 1b (early follow-up, same priority level but implemented after the core four are solid)

### Puppet (most important integration)

Puppet is Vigil's primary and most feature-rich integration. It encompasses multiple sub-systems (PuppetDB, Puppetserver, Hiera) that together provide the deepest infrastructure visibility. Vigil supports both Puppet Enterprise and Open Source Puppet/OpenVox.

**Capabilities:**

- **Inventory**: Node list from PuppetDB certnames (active, deactivated, expired) and Puppetserver CA certificate status (signed, requested, revoked)
- **Facts**: Full structured facts from PuppetDB (OS, hardware, networking, custom facts) with efficient querying and caching
- **Configuration**:
  - Hiera hierarchical data browsing with key resolution showing which hierarchy level provides each value
  - Hiera key usage analysis across the Puppet codebase (which classes/profiles consume which keys)
  - Class-aware Hiera lookups (resolve values in the context of a node's assigned classes)
  - Compiled catalogs from Puppetserver (resource declarations, parameters, relationships)
  - Catalog diff across environments (compare what a node gets in production vs. staging)
  - Environment management and cache control on Puppetserver
- **Events**: Resource-level change events from PuppetDB — success, failure, noop, skipped — with old/new values, timestamps, file/line references, containment paths. Events are grouped by the report (Puppet run) that produced them.
- **Reports**: Puppet run reports with:
  - Summary metrics (resources: total/changed/failed/skipped, time breakdown by resource type)
  - Corrective change detection (drift from desired state)
  - Log entries with level, source, tags
  - Resource events with drill-down
  - Run history with trend visualization
  - Noop mode indication
  - Times spent on different puppet run phases

**Puppet-specific requirements:**
- PuppetDB queries where applicable must use PQL (Puppet Query Language) for efficient server-side filtering
- Support for mTLS authentication (client certificates) to PuppetDB and Puppetserver
- Catalog compilation must handle environment isolation
- Hiera data resolution must respect the full hierarchy (including per-node, per-environment, and common layers)
- Environments deployment via r10k/Code Manager operations (either via webhook, if available, or remote command execution)

### Bolt

Bolt is a separate integration providing agentless remote execution via the Puppet Bolt CLI. It has its own inventory format independent of PuppetDB.

**Capabilities:**

- **Inventory**: Node list from Bolt inventory file (inventory.yaml) with groups, nested groups, and transport configuration (SSH, WinRM)
- **Remote Execution**:
  - Ad-hoc shell command execution on target nodes
  - Puppet task execution with automatic parameter discovery from task metadata
  - Plan execution with automatic parameter discovery
  - Package management (install, remove, update) across distributions

### Ansible

- **Inventory**: Node list from Ansible inventory (static files or dynamic inventory scripts) with groups, nested groups, and host/group variables
- **Facts**: Node facts gathered via the Ansible setup module
- **Remote Execution**:
  - Ad-hoc shell command execution via the shell module
  - Playbook execution with extra variables support
  - Package management (install, remove, update) across distributions

### SSH

- **Inventory**: Node list from SSH config file (~/.ssh/config or custom path) with host aliases and connection parameters
- **Facts**: System facts gathered via SSH commands (OS detection, hardware info, network interfaces)
- **Remote Execution**:
  - Shell command execution with connection pooling
  - Package management across Linux distributions (apt, yum, dnf, zypper)
  - Concurrent execution with configurable limits

### Proxmox

- **Inventory**: VM and LXC container list across all Proxmox cluster nodes with status, type (qemu/lxc), and resource allocation
- **Facts**: Guest configuration, resource usage (CPU, memory, disk), network configuration
- **Provisioning**:
  - Create VMs (from templates, ISOs, or clone)
  - Create LXC containers (from templates)
  - Destroy VMs and containers
  - Lifecycle: start, stop, shutdown, reboot, suspend, resume
  - Resource discovery: cluster nodes, storage pools, templates, ISO images, networks
  - Journal must be populated with lifetime events via realtime requests to APIs, not locally stored data.


### AWS

- **Inventory**: EC2 instance list with status, tags, region, VPC, subnet attribution; automatic grouping by region, VPC, and tags
- **Facts**: Instance metadata (type, AMI, launch time, security groups, network interfaces, public/private IPs)
- **Provisioning**:
  - Launch EC2 instances (with AMI, instance type, VPC, subnet, security group, key pair selection)
  - Terminate instances
  - Lifecycle: start, stop, reboot
  - Resource discovery: regions, instance types, AMIs (with filtering), VPCs, subnets, security groups, key pairs
  - Journal must be populated with lifetime events via realtime requests to APIs, not locally stored data.

### Azure

- **Inventory**: Azure VM list with status, location, resource group, tags; automatic grouping by location, resource group, and tags
- **Facts**: VM configuration (size, image, OS disk, network interfaces, public/private IPs)
- **Provisioning**:
  - Create VMs (with size, image, resource group, location, network configuration)
  - Lifecycle: start, stop, restart, deallocate
  - Resource discovery: locations, VM sizes, images, resource groups
  - Journal must be populated with lifetime events via realtime requests to APIs, not locally stored data.

---

## Integrations — Priority 2 (Next phase)

| Integration | Inv | Facts | Config | Events | Mon | Reports | Exec | Prov | Deploy |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **GCP Compute** | ✓ | ✓ | — | — | — | — | — | ✓ | — |
| **Icinga / Nagios** | ✓ | — | — | ✓ | ✓ | — | — | — | — |
| **CheckMK** | ✓ | ✓ | — | ✓ | ✓ | — | — | — | — |
| **Terraform / OpenTofu** | ✓ | — | ✓ | ✓ | — | — | — | ✓ | — |
| **Nessus / OpenVAS / Qualys** | — | — | — | — | — | ✓ | — | — | — |
| **Wazuh / OSSEC** | — | — | — | ✓ | ✓ | — | — | — | — |
| **Foreman / Satellite** | ✓ | ✓ | ✓ | ✓ | — | ✓ | — | ✓ | — |
| **oVirt / RHEV** | ✓ | ✓ | — | — | — | — | — | ✓ | — |
| **Prometheus + node_exporter** | — | — | — | — | ✓ | — | — | — | — |
| **GLPI** | ✓ | ✓ | — | — | — | — | — | — | — |
| **ArgoCD / Flux** | — | — | — | ✓ | — | — | — | — | ✓ |
| **Kubernetes** (node-level) | ✓ | ✓ | — | ✓ | — | — | — | — | ✓ |
| **AWX / Ansible Tower** | ✓ | — | — | ✓ | — | — | ✓ | — | — |

---

## Integrations — Priority 3 (Future / community-driven)

| Integration | Inv | Facts | Config | Events | Mon | Reports | Exec | Prov | Deploy |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **VMware vSphere** | ✓ | ✓ | — | ✓ | — | — | — | ✓ | — |
| **Libvirt / KVM** | ✓ | ✓ | — | — | — | — | — | ✓ | — |
| **LXD / Incus** | ✓ | ✓ | — | — | — | — | — | ✓ | — |
| **MAAS** | ✓ | ✓ | — | — | — | — | — | ✓ | — |
| **Zabbix** | ✓ | ✓ | — | ✓ | ✓ | — | — | — | — |
| **Datadog** | ✓ | — | — | ✓ | ✓ | — | — | — | — |
| **Consul** | ✓ | ✓ | — | — | ✓ | — | — | — | — |
| **CrowdStrike / Falcon** | ✓ | — | — | ✓ | ✓ | — | — | — | — |
| **Lynis / OpenSCAP** | — | — | — | — | — | ✓ | — | — | — |
| **Rudder** | ✓ | ✓ | ✓ | ✓ | — | ✓ | — | — | — |
| **NetBox** | ✓ | ✓ | — | — | — | — | — | — | — |
| **Snipe-IT** | ✓ | ✓ | — | — | — | — | — | — | — |
| **FreeIPA / Active Directory** | ✓ | ✓ | — | — | — | — | — | — | — |
| **Spacewalk / Uyuni** | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — |
| **Rundeck** | — | — | — | ✓ | — | — | ✓ | — | — |
| **SaltStack** | ✓ | ✓ | ✓ | ✓ | — | — | ✓ | — | — |
| **Chef / Cinc** | ✓ | ✓ | ✓ | ✓ | — | ✓ | — | — | — |
| **Capistrano / Deployer** | — | — | — | ✓ | — | — | — | — | ✓ |
| **Octopus Deploy** | — | — | — | ✓ | — | — | — | — | ✓ |
| **Jenkins / GitLab CI** | — | — | — | ✓ | — | — | — | — | ✓ |

---

## Scope Boundary

Vigil exposes capabilities that relate to **NODE LIFECYCLE** and **NODE VISIBILITY**. It does not replicate tool-specific management features. Specifically:

**In scope:**
- Viewing node inventory, facts, configuration, events, reports, monitoring status
- Executing commands/tasks/playbooks on nodes
- Managing VM/container lifecycle (create, destroy, start, stop, reboot)
- Browsing resource options for provisioning (templates, images, sizes)
- Cross-tool journal and event timeline
- RBAC for all of the above
- r10k/Code Manager operations

**Out of scope:**
- Cloud billing, cost management, or budget alerts
- Storage pool management, network topology configuration
- Puppet code editing, module management
- Monitoring rule configuration (adding/editing checks, notification rules)
- CI/CD pipeline management or deployment triggering
- Kubernetes pod/service/deployment management (only node-level visibility)

When in doubt: if a feature is about "what's happening on/to a node," it's in scope. If it's about "managing the tool itself," it's out of scope.

---

## Remote Execution Model

Integrations that do not expose APIs (Bolt, Ansible, SSH) work by invoking CLI tools or establishing SSH connections as the system user running Vigil. The principle is:

**Vigil does on your infrastructure what you can do from the machine it runs on, with the permissions of the user it runs as.**

This means:
- Bolt execution invokes the `bolt` CLI with the configured project directory
- Ansible execution invokes `ansible` / `ansible-playbook` with the configured inventory
- SSH execution establishes connections using the configured SSH keys and config
- No agent is required on target nodes (agentless model for execution)
- The system user's permissions and network access define what Vigil can reach
- Security controls (command whitelist, RBAC) are enforced BEFORE invoking the underlying tool

---

## Testing Philosophy

Tests must verify user-visible behavior and catch real failures. Low-value tests that pass while the product is broken are worse than no tests.

**High-value tests (MUST have):**
- **Integration tests for API endpoints**: Does the API return the correct data shape? Does authentication work? Do permissions block unauthorized access?
- **End-to-end tests for critical flows**: Can a user browse inventory, execute a command, and see streaming output? Can a user provision a VM and see it appear in inventory?
- **Property-based tests for complex logic**: Node identity linking (does deduplication work correctly across thousands of nodes with ambiguous identities?), RBAC permission evaluation (do permission combinations resolve correctly?), journal event extraction from reports (are the right events extracted and grouped?)
- **Resilience tests**: Does the system degrade gracefully when an integration is unavailable? Do timeouts work? Does the circuit breaker trip and recover?

**Low-value tests (skip or minimize):**
- Unit tests for trivial CRUD operations
- Tests that only verify mocked API wrappers return what the mock was told to return
- Tests for pure UI rendering without user interaction
- Tests that duplicate what the type system already guarantees

**Testing principle:** If a test wouldn't catch a bug that a user would notice, it's not worth writing.

---

## AI-Assisted Features (Priority 2)

### MCP Server

Vigil exposes an MCP (Model Context Protocol) server with well-optimized, read-only infrastructure tools. This allows external AI agents and tools (IDE assistants, chat interfaces, automation pipelines) to query infrastructure state.

Requirements:
- Expose read-only infrastructure tools (inventory queries, node facts, status checks, group membership, journal queries). Write abilities like remote execution or provisioning may be planned in the future.
- Tools must be optimized for AI consumption (structured responses, reasonable token sizes, pre-summarized where appropriate)
- Respect RBAC: MCP tool access follows the same permission model as the web UI
- Must not expose execution or provisioning capabilities without explicit opt-in
- Tool responses must be cacheable and efficient (no flooding upstream APIs per AI query)

### AI-Assisted Inference (Priority 2)

Vigil provides embedded AI-assisted features using a bring-your-own-keys model for LLM access:

- **Contextual analysis buttons**: One-click AI-generated insights on node state (e.g., "Analyze recent failures," "Summarize configuration drift," "Explain this node's event history")
- **AI-generated reports**: Embedded, optimized prompts that produce structured reports from infrastructure data (e.g., "Weekly change summary," "Nodes at risk," "Unused resources")
- **Smart suggestions**: AI-powered recommendations based on patterns in events and facts (e.g., "These 3 nodes have the same failure pattern — likely related")

This is NOT a general-purpose chat interface. It's targeted inference triggered by specific UI entry points with pre-crafted prompts optimized for infrastructure context.

Requirements:
- Bring-your-own-keys: users configure their own LLM API keys (OpenAI, Anthropic, local models)
- Prompts are embedded and optimized — not user-authored free-form queries
- AI features are optional and gracefully absent when no LLM key is configured
- All AI inputs are constructed from data the user already has permission to see (RBAC-scoped)

---

## Core Platform Requirements

### Unified Inventory
- Multi-source node aggregation with deduplication and identity linking (by hostname, certname, FQDN, IP)
- **Automatic linking**: Heuristic-based matching using configurable rules (match by certname, match by FQDN, match by IP, etc.)
- **Manual linking**: Administrators can explicitly link or unlink nodes across sources on a per-node basis, overriding automatic heuristics
- **Linking rules configuration**: Global rules define the matching strategy (e.g., "prefer certname, fall back to FQDN"). Rules can be adjusted without re-processing the entire inventory.
- Source attribution: each node shows which integrations know about it
- Inventory groups from all sources, linked by name across sources
- Graceful degradation: system continues operating when individual sources are unavailable or slow
- Pagination and search must work efficiently at thousands-of-nodes scale
- Inventory caching with configurable TTL to avoid flooding upstream APIs

### Remote Execution
- Unified execution interface across all execution-capable integrations
- Real-time streaming output (stdout/stderr) delivered to the UI as it arrives
- Execution history with full output preservation and metadata
- Re-execution of previous commands with one click
- Concurrent execution limits (configurable per-integration and globally)
- Command security controls (whitelist/allowlist approach)
- Target selection by node, group, or ad-hoc list

### Node Journal / Event Timeline
- Per-node timeline of all significant events (provisioning, execution, configuration changes, monitoring state changes, deployments, manual notes)
- Global timeline with filtering by: node, group, event type, source integration, date range
- Events sourced from both stored records and live integration queries
- Manual notes capability (user-authored journal entries)
- Journal entries link back to their source (report detail, execution output, etc.)

### Authentication & Authorization
- Role-based access control (RBAC) with configurable roles and permissions
- Per-integration permission granularity (e.g., can view Puppet data but cannot execute commands)
- Audit trail of user actions
- Local authentication (built-in user management) for Priority 1

**Priority 2 — External Authentication:**
- SAML 2.0 (for enterprise SSO: Okta, Azure AD, ADFS, Keycloak)
- OIDC / OAuth 2.0 (Google, GitHub, generic providers)
- LDAP / Active Directory (direct bind or search-based)
- **Group-to-Role Mapping**: External groups are mapped to Vigil roles via admin-configured mapping rules:
  - Roles are defined in Vigil with specific permission sets
  - Admin maps external groups to one or more Vigil roles
  - Multiple group memberships are additive (union of permissions)
  - Configurable default role for unmapped users (minimal role or deny access)
  - JIT (just-in-time) user provisioning on first login — no pre-provisioning needed
  - External users authenticate only via their IdP (no local password)
  - Local users coexist for initial setup, break-glass access, or environments without an IdP
  - Mapping supports wildcards/patterns (e.g., groups matching `vigil-*` map to the role named after the suffix)

**Priority 2 — Granular Execution Permissions:**
- Remote Execution and Provisioning actions support fine-grained per-action permissions within roles:
  - Per-command restrictions (which shell commands a role is allowed to execute)
  - Per-task restrictions (which Bolt tasks or Ansible modules a role can run)
  - Per-playbook restrictions (which playbooks a role can trigger)
  - Per-provisioning-action restrictions (which lifecycle operations — create, destroy, start, stop — a role can perform, and on which integrations)
- These granular permissions are defined within Vigil roles and enforced regardless of authentication method

### Health & Observability
- Per-integration health checks with caching and configurable intervals
- Degraded state detection: integration partially functional (some capabilities work, others don't)
- Integration status dashboard showing all integrations and their health
- Timeout handling: slow integrations don't block the entire system

### Resilience

All integrations must implement resilience patterns appropriate to their communication model:

**API-based integrations** (PuppetDB, Puppetserver, Proxmox, AWS, Azure, monitoring tools, etc.):
- Circuit breaker: after N consecutive failures, stop calling the API for a cooldown period before retrying
- Retry with exponential backoff: transient failures are retried automatically with increasing delays
- Configurable thresholds: failure count, cooldown duration, and max retries per integration

**CLI-based integrations** (Bolt, Ansible, SSH):
- Execution timeout: maximum wall-clock time before killing the process (configurable per-integration and per-command)
- Idle timeout: if no output received for N seconds, consider the process hung and terminate it
- Both thresholds configurable with sensible defaults

**All integrations:**
- Per-integration timeout for any external call (API request or CLI invocation)
- Health check failures must not cascade — one unhealthy integration must not affect others
- Recovery detection: when a circuit breaker opens, periodic probes detect recovery and restore normal operation

### Plugin Architecture

All integrations — whether shipped with Vigil or provided by the community — follow the same plugin contract. There is no distinction in how built-in and external integrations are handled.

**Plugin contract:**
- Each plugin declares which of the 9 integration types it provides
- Each plugin declares its configuration schema (what settings it needs)
- Each plugin implements lifecycle hooks: initialize, health check, shutdown
- Each plugin implements data contracts per declared integration type (standardized return shapes for Inventory, Facts, Events, etc.)
- Each plugin reports errors through a standardized error contract

**Plugin distribution:**
- First-party plugins (Puppet, Bolt, Ansible, SSH, Proxmox, AWS, Azure) ship with the application
- Community plugins are distributed as packages and loaded at runtime
- Both follow the exact same interface — no special treatment for built-in plugins
- Plugin discovery and registration happens at application startup
- Plugins can be enabled/disabled via configuration without code changes

**Plugin isolation:**
- A failing plugin must not crash the application
- Plugins run within the application runtime (not separate processes) for performance
- Resource limits (memory, connection pools) are configurable per plugin

### Performance & Scale
- Must handle inventories of several thousand nodes without degradation
- Aggressive caching with configurable TTL per integration type
- Request deduplication: identical concurrent requests share a single upstream call
- Pagination for all list endpoints
- Per-source timeouts to prevent slow integrations from blocking aggregation
- Background refresh of cached data (don't make users wait for cold caches)
- Efficient incremental updates where upstream APIs support them

### Configuration
- Single configuration source for all integrations
- Per-integration enable/disable
- Configuration validation at startup with clear error messages
- Sensitive values (tokens, passwords, certificates) handled securely
- Setup assistance: guided configuration with validation feedback

---

## Node Detail Page — Information Architecture

Each node's detail page aggregates data from all integration types. **The UI is driven by enabled integrations**: disabled integrations produce zero UI footprint (no tabs, no sections, no menu items). Enabled but failing integrations show their sections with degradation indicators.

| Section | Source Type | Behavior |
|---------|------------|----------|
| Identity & Status | Inventory | Source attribution, linked identities |
| System Facts | Facts | OS, hardware, network, packages — tabular |
| Health & Monitoring | Monitoring | Current check status, alerts — live-updating |
| Configuration | Configuration | Desired state, Hiera data, catalog — structured/hierarchical |
| Journal / Timeline | Events | Filterable event history |
| Run History | Reports | Past runs with metrics and drill-down |
| Deployments | Deployment | App versions and deploy history |
| Execute | Remote Execution | Command input with streaming output |
| Lifecycle | Provisioning | Start/stop/reboot controls (only for provisioning-capable sources) |

---

## Core Data Model (Conceptual)

The following entities and relationships form the conceptual backbone of the system. This is NOT a database schema — it defines the vocabulary and relationships that all features are built around.

### Core Entities

- **Node**: A managed server, VM, or container. Has a canonical identity (resolved from hostname, certname, FQDN, IP). Known by one or more integrations.
- **Integration**: A configured connection to an external tool (Puppet, Ansible, Proxmox, etc.). Declares which integration types it provides. Has health status and configuration.
- **Group**: A named collection of nodes. May originate from one or more integrations. Groups with the same name across sources are linked.
- **User**: An authenticated person or service account. Has one or more roles. May be local or externally authenticated.
- **Role**: A named set of permissions. Defines what actions a user can perform, on which integrations, and with what granularity.
- **Journal Entry**: A single significant event in a node's history. Has a type, source, timestamp, summary, and optional structured details.
- **Execution**: A remote command/task/playbook run against one or more nodes. Has streaming output, exit status, duration, and metadata. Generates a journal entry.
- **Report**: A structured result of a completed run or scan (e.g., Puppet run report). Contains metrics, logs, and resource-level details. May generate events.
- **Fact**: A key-value attribute of a node, observed at a point in time. Has a source and a gathered timestamp.
- **Configuration Item**: A desired-state declaration for a node (Hiera key, catalog resource, Ansible variable). Has a source, scope, and value.

### Key Relationships

- A **Node** is known by one or more **Integrations** (source attribution)
- A **Node** belongs to zero or more **Groups**
- A **Node** has zero or more **Facts** (from multiple sources, potentially overlapping)
- A **Node** has zero or more **Journal Entries** (ordered by time)
- A **Node** has zero or more **Reports** (ordered by time)
- A **Node** has zero or more **Configuration Items** (from multiple sources)
- A **Group** contains one or more **Nodes**
- A **Group** originates from one or more **Integrations** (linked groups span sources)
- An **Execution** targets one or more **Nodes** and produces one **Journal Entry** per node
- A **Report** belongs to one **Node** and may produce zero or more **Events** (journal entries)
- A **User** has one or more **Roles**
- A **Role** grants permissions scoped to integration types, specific integrations, or specific actions

---

## Key User Flows

These end-to-end scenarios describe how users interact with the system. Each flow should be fully supported by the requirements.

### Flow 1: Inventory Browsing and Node Inspection
1. User opens the inventory page
2. System displays paginated node list aggregated from all healthy integrations
3. User can filter by: group, source integration, status, fact values, free-text search
4. User selects a node → navigates to node detail page
5. Node detail page loads data from all integration types that know this node
6. Each section indicates its source and data freshness

### Flow 2: Remote Command Execution
1. User selects one or more nodes (or a group) as targets
2. User chooses an execution integration (Bolt, Ansible, SSH) and enters a command/task/playbook
3. System validates permissions (is this user allowed to run this command via this integration?)
4. System validates command against security controls (whitelist)
5. Execution begins — streaming output appears in real-time
6. On completion: result is stored in execution history, journal entry is created per target node
7. User can re-execute the same command later with one click

### Flow 3: VM Provisioning
1. User navigates to provisioning page
2. System shows available provisioning integrations and their resource options (templates, sizes, networks)
3. User fills provisioning form (integration-specific parameters)
4. System validates permissions and parameters
5. Provisioning begins — progress is reported
6. On completion: new node appears in inventory, journal entry records the provisioning event
7. Node is immediately available for execution and fact gathering

### Flow 4: Graceful Degradation
1. PuppetDB becomes unreachable (network issue, maintenance)
2. System detects failure via health check, marks Puppet integration as degraded
3. Inventory still shows nodes from other sources (Ansible, SSH, Proxmox, AWS, Azure)
4. Nodes that were ONLY known via PuppetDB show cached data with staleness indicator
5. User can still execute commands via Bolt/Ansible/SSH on any reachable node
6. Integration status dashboard shows PuppetDB as unhealthy with error details
7. When PuppetDB recovers, system resumes normal operation and refreshes stale caches

### Flow 5: Puppet Run with Changes → Journal
1. A Puppet agent runs on a node and makes configuration changes
2. PuppetDB receives the report with resource events
3. On next data refresh (or push notification if available), Vigil detects the new report
4. System extracts change events from the report (ignoring no-op/unchanged resources)
5. Journal entries are created for each change event, grouped under the report
6. User viewing the node's journal sees the grouped changes with drill-down to full report
7. No-change Puppet runs do NOT appear in the journal

### Flow 6: Large-Scale Inventory Search
1. User searches for all nodes running Ubuntu 22.04 across 5000+ nodes
2. System uses server-side filtering where possible (PQL for PuppetDB, API filters for cloud providers)
3. For sources without server-side filtering, system queries cached facts
4. Results are paginated and returned progressively (fast sources first)
5. UI remains responsive throughout — no blocking on slow sources

### Flow 7: Monitoring State Change → Journal
1. A monitoring integration (e.g., Icinga) detects a node going from OK to CRITICAL
2. Vigil receives the state change (via polling or webhook)
3. A journal entry is created: "Monitoring state changed: OK → CRITICAL (check: disk_usage)"
4. The node's monitoring section on the detail page updates to show current CRITICAL status
5. When the node recovers (CRITICAL → OK), another journal entry is created
6. Steady-state checks (node remains OK) do NOT generate journal entries

---

## Real-time & Streaming Requirements

### Streaming Execution Output
- Output from remote execution MUST appear in the UI within 200ms of generation on the target node (network latency permitting)
- Multiple users viewing the same execution MUST see the same stream
- If a user's connection drops during execution, reconnection MUST resume from the last received position (no lost output)
- Completed execution output MUST be fully preserved and retrievable after the stream ends
- The system MUST support concurrent streaming from multiple executions simultaneously

### Live-Updating Data
- Monitoring status SHOULD update in the UI without manual refresh (push-based or short-polling)
- Inventory changes (new nodes appearing, nodes going offline) SHOULD be reflected within the configured cache TTL
- Journal entries from external sources SHOULD appear without page refresh
- Provisioning progress MUST be reported in real-time (status transitions: pending → creating → running)

### Connection Resilience
- The UI MUST handle temporary network disconnections gracefully (show disconnected state, auto-reconnect)
- On reconnection, the UI MUST sync to current state without requiring full page reload
- Long-running operations (provisioning, execution) MUST NOT be affected by UI disconnection — they continue server-side

---

## Error Handling & Graceful Degradation

### Per-Integration Failure Handling
- When an integration is unreachable, the system MUST continue serving data from all other integrations
- Cached data from a failed integration MUST still be served, with a clear staleness indicator (last successful sync time)
- The UI MUST clearly indicate which integrations are healthy, degraded, or unavailable
- Integration failures MUST NOT produce user-facing error pages — they produce partial results with explanations

### Degraded State
- An integration MAY be partially functional (e.g., PuppetDB responds to inventory queries but times out on report queries)
- The system MUST track per-capability health, not just per-integration
- Degraded integrations MUST report which capabilities are working and which are failing

### Timeout Behavior
- Each integration MUST have a configurable timeout for API calls
- Aggregation operations (e.g., unified inventory) MUST NOT wait for the slowest source — fast sources return immediately, slow sources are included when ready or skipped on timeout
- The UI MUST indicate when results are incomplete due to timeouts ("3 of 4 sources responded")

### User Communication
- Error messages MUST be actionable: what failed, why (if known), and what the user can do (retry, check configuration, contact admin)
- Transient errors (network blips) SHOULD be retried automatically with backoff
- Persistent errors SHOULD be surfaced in the integration status dashboard with diagnostic details

---

## Future Considerations (Priority 3)

These features are planned but deferred beyond the initial phases:

### CLI Tool
A command-line interface (`vigil`) that provides terminal-based access to Vigil's capabilities:
- Query inventory, facts, and node status from the terminal
- Execute commands on nodes without opening the web UI
- View journal entries and execution history
- Authenticate via API token or session
- Output formats: human-readable (default), JSON (for scripting), table
- Useful for automation scripts, CI/CD pipelines, and power users who prefer the terminal
- Must use the same API and respect the same RBAC as the web UI

### Scheduled Executions
- Cron-like scheduling for recurring commands/tasks/playbooks
- Schedule management UI with history of past runs
- Alerting on scheduled execution failures

### Custom Dashboards
- User-configurable dashboard views with widgets (node counts, recent events, health summary, custom queries)
- Shareable dashboard configurations across team members

---

## Implementation Roadmap

The project is implemented as ordered feature sets. Each feature set is a self-contained unit with clear scope, acceptance criteria, and required tests. Feature sets are tackled in the order listed — each builds on the previous.

### Feature Set 1: Core Platform + Plugin SDK
**Scope:** Application skeleton, plugin contract definition, configuration system, health check framework, basic HTTP server with no integrations yet.
**Acceptance criteria:**
- Plugin contract is defined and documented
- A plugin can be registered, initialized, health-checked, and shut down
- Configuration is loaded, validated, and accessible to plugins
- Health check endpoint returns status of all registered plugins
- A "no-op" test plugin can be loaded to verify the contract

### Feature Set 2: SSH Integration
**Scope:** First real integration. Proves the plugin contract works end-to-end.
**Acceptance criteria:**
- SSH config file is parsed into inventory
- Nodes appear in the inventory API
- Facts can be gathered via SSH commands
- Commands can be executed with streaming output
- Execution history is stored and retrievable
- Health check reports SSH connectivity status

### Feature Set 3: Authentication + RBAC
**Scope:** Local user management, JWT/session auth, role-based permissions.
**Acceptance criteria:**
- Users can register, log in, log out
- Roles with permissions can be created and assigned
- API endpoints enforce permissions (unauthorized requests are rejected)
- Audit trail records user actions

### Feature Set 4: Puppet Integration (Inventory + Facts)
**Scope:** PuppetDB connection, node inventory, facts retrieval. Read-only.
**Acceptance criteria:**
- PuppetDB nodes appear in unified inventory alongside SSH nodes
- Node identity linking works between Puppet certnames and SSH hostnames
- Facts are retrievable per node from PuppetDB
- Circuit breaker trips on PuppetDB failures and recovers
- mTLS authentication works with client certificates

### Feature Set 5: Bolt Integration (Inventory + Execution)
**Scope:** Bolt inventory parsing, command and task execution.
**Acceptance criteria:**
- Bolt inventory.yaml is parsed into nodes and groups
- Commands can be executed via Bolt CLI with streaming output
- Tasks are discoverable with parameter metadata
- Execution timeout and idle timeout work correctly

### Feature Set 6: Puppet Integration (Events + Reports + Configuration)
**Scope:** Full Puppet depth — reports, events, catalogs, Hiera.
**Acceptance criteria:**
- Puppet reports are retrievable with metrics and resource events
- Change events are extracted from reports correctly (no-change runs are silent)
- Catalogs are retrievable with resource relationships
- Catalog diff between environments works
- Hiera data is browsable with hierarchy level attribution
- Hiera key usage analysis returns consuming classes

### Feature Set 7: Ansible Integration
**Scope:** Ansible inventory, facts, command/playbook execution.
**Acceptance criteria:**
- Ansible inventory (static + dynamic) is parsed into nodes and groups
- Facts are gatherable via setup module
- Ad-hoc commands execute with streaming output
- Playbooks execute with extra vars support
- Plugin contract is identical to SSH/Bolt (validates generality)

### Feature Set 8: Node Journal
**Scope:** Journal storage, event extraction from reports, manual notes, global timeline.
**Acceptance criteria:**
- Journal entries are created from executions, provisioning actions, and Puppet events
- Per-node timeline is filterable by type, source, date range
- Global timeline works with cross-node filtering
- Manual notes can be added by users
- Journal entries link back to their source (report, execution)

### Feature Set 9: Unified Inventory (Linking + Deduplication)
**Scope:** Cross-integration node identity resolution, manual linking, group linking.
**Acceptance criteria:**
- Automatic linking correctly merges nodes across sources by configurable rules
- Manual link/unlink overrides work per-node
- Linked nodes show source attribution from all contributing integrations
- Groups with same name across sources are linked
- Deduplication handles 5000+ nodes without performance degradation

### Feature Set 10: Provisioning (Proxmox)
**Scope:** First provisioning integration.
**Acceptance criteria:**
- Proxmox VMs and containers appear in inventory
- VMs can be created, destroyed, started, stopped
- Resource discovery (templates, storage, networks) works
- Provisioning actions generate journal entries
- Newly provisioned nodes appear in inventory immediately

### Feature Set 11: Provisioning (AWS + Azure)
**Scope:** Cloud provisioning integrations.
**Acceptance criteria:**
- EC2 instances and Azure VMs appear in inventory with grouping
- Instances can be launched/terminated with resource selection
- Lifecycle actions (start, stop, reboot) work
- Resource discovery returns available options
- Journal is populated from cloud API events

### Feature Set 12: External Authentication
**Scope:** SAML, OIDC, LDAP integration with group-to-role mapping.
**Acceptance criteria:**
- Users can authenticate via external IdP
- Group-to-role mapping correctly assigns permissions
- JIT provisioning creates user on first login
- Local users continue to work alongside external auth

### Feature Set 13: MCP Server
**Scope:** Read-only MCP tools for AI agents.
**Acceptance criteria:**
- MCP server exposes inventory, facts, journal, and status tools
- Tool responses are structured and token-efficient
- RBAC is enforced on MCP tool access
- Tools don't flood upstream APIs (caching works)

### Feature Set 14: AI-Assisted Inference
**Scope:** Contextual analysis buttons, AI-generated reports.
**Acceptance criteria:**
- Bring-your-own-keys configuration works for multiple LLM providers
- Contextual analysis produces useful insights from node data
- AI features are gracefully absent when no key is configured
- All AI inputs respect RBAC (no data leakage)

---

## Document Structure

Please structure the document as follows:

1. **Executive Summary** — product vision, target users, value proposition, scale requirements
2. **Glossary** — key terms and definitions
3. **Scope Boundary** — what's in scope (node lifecycle + visibility) and what's explicitly out of scope
4. **Integration Types** — formal definition of each of the 9 integration types
5. **Integration Matrix** — which integrations provide which types, organized by priority and phase
6. **Plugin Architecture** — uniform plugin contract, distribution model, lifecycle, isolation
7. **Priority 1 Integration Specifications** — detailed requirements for Phase 1 (Puppet, Bolt, Ansible, SSH) and Phase 1b (Proxmox, AWS, Azure)
8. **Priority 2 & 3 Integration Specifications** — lighter specifications for future integrations
9. **Platform Requirements** — cross-cutting concerns (unified inventory, remote execution model, journal, auth, health, resilience, performance, configuration)
10. **Core Data Model** — entities, relationships, and conceptual structure
11. **Key User Flows** — end-to-end scenarios (inventory browsing, execution, provisioning, degradation, journal population)
12. **Real-time & Streaming Requirements** — streaming output, live updates, connection resilience
13. **Error Handling & Graceful Degradation** — failure modes, timeout behavior, user communication
14. **Testing Philosophy** — what to test, what not to test, testing levels that matter
15. **AI-Assisted Features** — MCP server, AI inference entry points, bring-your-own-keys model
16. **User Interface Requirements** — information architecture, node detail page, UI driven by enabled integrations
17. **Non-Functional Requirements** — performance at scale, security, reliability, extensibility, caching strategy
18. **Implementation Roadmap** — ordered feature sets with acceptance criteria
19. **Future Considerations** — planned features (scheduled executions, custom dashboards, CLI tool)

---

## Constraints

- **Do NOT reference any specific programming language, framework, or implementation technology.** The document should be implementation-agnostic.
- **Do NOT reference any existing codebase structure or design patterns.** Write as if designing from scratch.
- Use clear, testable requirement statements (MUST, SHOULD, MAY per RFC 2119).
- Each requirement should have a unique identifier for traceability (e.g., INV-001, EXEC-003, PUPPET-012).
- Focus on WHAT the system does, not HOW it does it.
- Requirements must account for the scale target of several thousand nodes.
- Puppet is the most important integration — give it the most detailed specification.
- Bolt is a separate integration from Puppet — do not merge them.

---

## Notes for the Requester

- This is a **new project** designed from scratch with the full scope in mind from day one. It is not a rewrite of an existing codebase — it's a clean-slate design informed by lessons learned from a prior implementation.
- The architecture must accommodate all 9 integration types from the start, even if only Phase 1 integrations (Puppet, Bolt, Ansible, SSH) are implemented initially. The integration plugin contract must be extensible without architectural changes.
- Priority 1 integrations should have detailed, testable requirements. Priority 2/3 can be lighter (capability descriptions + key constraints).
- Phase 1 = Puppet + Bolt + Ansible + SSH. Phase 1b = Proxmox + AWS + Azure. Phase 2 = everything else.
- You may want to iterate: first pass for structure and completeness, second pass for requirement precision and testability.
- The planned implementation target is Elixir + Phoenix LiveView, which is well-suited for real-time streaming, live-updating views, PubSub-driven event delivery, and fault-tolerant supervision — but the spec itself should remain technology-neutral.
- Node identity linking must support both automatic heuristics (hostname/certname/FQDN matching) AND manual per-node linking by administrators. The spec should define both mechanisms.

# 10. Priority 2 & 3 Integration Specifications

This section covers integrations beyond the Phase 1 / 1b scope. Specifications here are intentionally lighter than for Priority 1 plugins. The plugin contract and integration-type definitions ([sections 4](04-integration-types.md) and [6](06-plugin-architecture.md)) are normative for these plugins; the per-plugin notes below define each plugin's scope, the surfaces it touches, and any tool-specific constraints worth recording at the requirements level.

A Priority 2 or Priority 3 plugin's full specification is to be drafted at the start of its implementation phase and added as an annex to this document. The notes here are sufficient for product planning, capability matrix integrity, and contract validation — they are not sufficient as implementation specifications on their own.

## 10.1 Common requirements for all subsequent integrations

| ID | Requirement |
|----|-------------|
| `P2-COM-001` | All Priority 2 and 3 plugins **MUST** conform to the plugin contract defined in [section 6](06-plugin-architecture.md). No plugin is exempt. |
| `P2-COM-002` | All Priority 2 and 3 plugins **MUST** declare exactly the integration types listed for them in the [integration matrix](05-integration-matrix.md), and no others, without an amendment to this document. |
| `P2-COM-003` | All plugins **MUST** define their own configuration schema, credentials handling, RBAC permissions, journal contributions, and resilience defaults consistent with the integration types they declare. |
| `P2-COM-004` | All plugins **MUST** be enable/disable-able independently of any other plugin. |
| `P2-COM-005` | Plugins providing Inventory **MUST** declare identity confidence and identity attributes consistent with [section 11.1](11-platform-requirements.md) so the linking engine can incorporate them correctly. |
| `P2-COM-006` | Plugins providing Events or Monitoring **MUST** distinguish state transitions from steady-state observations, per the rules in [section 4](04-integration-types.md). |

## 10.2 Priority 2 — Notes per integration

### 10.2.1 GCP Compute

**Capabilities:** Inventory, Facts, Provisioning.

**Scope notes:** GCE instance lifecycle and discovery; group derivation from labels, projects, regions, and zones. Multiple projects per integration. Authentication via service account JSON or workload identity. Journal populated from Cloud Audit Logs in real time. RBAC: GCP IAM permissions are the upstream constraint; plugin documents required roles.

**Comparable to:** AWS / Azure plugins (see [section 9](09-priority-1b-integrations.md)). Implementation parity with the Phase 2a cloud plugins is expected.

### 10.2.2 Icinga / Nagios

**Capabilities:** Inventory, Events, Monitoring.

**Scope notes:** Hosts and services as inventory; current check state as Monitoring; state transitions as Events. Vigil **MUST NOT** create or modify checks. Inventory linking by FQDN (and optionally by Icinga `host_name` if it differs from FQDN). API authentication via API user. Live updates via Icinga Streams API where available; short-polling otherwise.

### 10.2.3 CheckMK

**Capabilities:** Inventory, Facts, Events, Monitoring.

**Scope notes:** Hosts as inventory; HW/SW inventory as Facts (CheckMK's own inventory data is rich and **MUST** be presented as Facts when retrieved); current service state as Monitoring; state transitions as Events. CheckMK Facts **MUST** be marked opportunistic where they overlap with Puppet or SSH-derived facts, except CheckMK-specific data points (HW asset details, software version inventory) for which CheckMK is authoritative.

### 10.2.4 Terraform / OpenTofu

**Capabilities:** Inventory, Configuration, Events, Provisioning.

**Scope notes:** Inventory comes from Terraform state — resources of types representing nodes (compute instances, VMs, containers). Configuration is the desired state declared in the parsed plan or state. Events reflect plan/apply outcomes per resource. Provisioning is via running `terraform apply` / `terraform destroy` on a configured workspace. Vigil **MUST NOT** modify Terraform configuration files; it **MAY** trigger plan/apply with parameters. Configuration scope: resources owned by Terraform, not the desired state of the node's interior.

**Important constraint:** Provisioning here means triggering a `terraform apply` against an existing workspace. Authoring HCL is out of scope.

### 10.2.5 Nessus / OpenVAS / Qualys

**Capabilities:** Reports.

**Scope notes:** Vulnerability scan results as Reports. Each scan run is a Report; per-finding detail is the resource-equivalent. The plugin **MUST NOT** allow scan profile authoring. The plugin **MAY** allow re-execution of an existing scan profile against a target — modeled as Remote Execution of a known artifact, requiring the scanner integration to also declare Remote Execution if this capability is offered.

For the initial scope (Reports only), the plugin is read-only.

### 10.2.6 Wazuh / OSSEC

**Capabilities:** Events, Monitoring.

**Scope notes:** Security events as Events; agent health and current alert state as Monitoring. The plugin **MUST NOT** modify Wazuh rules, decoders, or agent configuration. Live alerts via Wazuh API; historical events via the alerts archive.

### 10.2.7 Foreman / Satellite

**Capabilities:** Inventory, Facts, Configuration, Events, Reports, Provisioning.

**Scope notes:** Among the richest Priority 2 integrations. Hosts as inventory; Foreman facts as Facts; host group / parameter overrides / Puppet integration as Configuration; configuration reports as Reports; orchestration tasks as Events; host build/destroy as Provisioning.

If Foreman's Puppet integration is configured, the plugin **MUST** still defer to a separately-configured Puppet plugin for authoritative Puppet data; Foreman serves as a wrapper view, not as the canonical Puppet source.

### 10.2.8 oVirt / RHEV

**Capabilities:** Inventory, Facts, Provisioning.

**Scope notes:** VMs and hosts; lifecycle operations; resource discovery (clusters, storage domains, networks). Authentication via SSO token. Journal populated from oVirt event log via realtime queries.

### 10.2.9 Prometheus + node_exporter

**Capabilities:** Monitoring.

**Scope notes:** Live node-level metrics from `node_exporter` (CPU, memory, disk, network) presented as Monitoring data. The plugin **MUST NOT** ingest or store metrics; it queries Prometheus on demand. Live updates via short-polling.

The plugin **MUST NOT** declare Inventory — Prometheus targets are not authoritative node identity.

### 10.2.10 GLPI

**Capabilities:** Inventory, Facts.

**Scope notes:** Computers / network equipment from GLPI as Inventory; asset details (model, serial, location, ownership, financial info) as Facts. The plugin is read-only. Identity linking by hostname or asset identifier.

### 10.2.11 ArgoCD / Flux

**Capabilities:** Events, Deployment.

**Scope notes:** Application sync events as Events; deployment history (revisions, sync results) as Deployment. The plugin **MUST NOT** trigger syncs, rollbacks, or modify Application/HelmRelease resources. Linking happens at the Kubernetes node level (deployments live on nodes); the plugin **MUST** correlate with the Kubernetes node-level integration if also enabled.

### 10.2.12 Kubernetes (node-level)

**Capabilities:** Inventory, Facts, Events, Deployment.

**Scope notes:** Kubernetes **nodes** as Inventory (not pods); node conditions and capacity as Facts; node-related events from the Kubernetes event API as Events; the *workloads running on* each node (which Pods of which Deployments/StatefulSets/DaemonSets are scheduled there) as Deployment data, read-only.

Out of scope for this plugin: pod management, deployment management, exec'ing into pods, scaling workloads, anything above the node level.

### 10.2.13 AWX / Ansible Tower

**Capabilities:** Inventory, Events, Remote Execution.

**Scope notes:** AWX inventory mirrored as Vigil inventory; AWX job runs as Events; job templates triggered as Remote Execution. The plugin **MUST NOT** create or modify job templates, projects, or credentials in AWX — it triggers existing artifacts. Authentication via OAuth token.

## 10.3 Priority 3 — Notes per integration

The following integrations are backlog candidates. Their inclusion here documents intent and capability declarations; full specifications are produced when the plugin enters implementation. The notes are deliberately brief.

### 10.3.1 VMware vSphere

Inventory, Facts, Events, Provisioning. VMs and hosts; vCenter task log feeds journal via realtime queries. Authentication via vSphere SSO.

### 10.3.2 Libvirt / KVM

Inventory, Facts, Provisioning. Local or remote libvirt connection; domains and storage pools. Lower-level than Proxmox; no clustering.

### 10.3.3 LXD / Incus

Inventory, Facts, Provisioning. Containers as nodes; profile and storage discovery.

### 10.3.4 MAAS

Inventory, Facts, Provisioning. Bare-metal lifecycle; commissioning, deploy, release. Hardware facts from MAAS commissioning data.

### 10.3.5 Zabbix

Inventory, Facts, Events, Monitoring. Hosts, host inventory, problem events, current trigger state.

### 10.3.6 Datadog

Inventory, Events, Monitoring. Hosts as inventory; events from Datadog event stream; current monitor state. Read-only.

### 10.3.7 Consul

Inventory, Facts, Monitoring. Service catalog; node metadata; service health states.

### 10.3.8 CrowdStrike / Falcon

Inventory, Events, Monitoring. Endpoints; detections; sensor health.

### 10.3.9 Lynis / OpenSCAP

Reports. Hardening / compliance scan results as structured reports with finding-level detail.

### 10.3.10 Rudder

Inventory, Facts, Configuration, Events, Reports. Conceptually parallel to Puppet/Chef in coverage; fewer Vigil deployments expected to use it, hence Priority 3.

### 10.3.11 NetBox

Inventory, Facts. DCIM/IPAM source of truth; rack, location, IP, role data as Facts.

### 10.3.12 Snipe-IT

Inventory, Facts. Asset management source; serial, ownership, lifecycle status as Facts.

### 10.3.13 FreeIPA / Active Directory

Inventory, Facts. Hosts enrolled in directory services; group memberships; OU placement.

### 10.3.14 Spacewalk / Uyuni

Inventory, Facts, Events, Reports. System inventory; package facts; errata/audit events; patch reports.

### 10.3.15 Rundeck

Events, Remote Execution. Job runs as events; job execution as Remote Execution. The plugin **MUST NOT** author job definitions.

### 10.3.16 SaltStack

Inventory, Facts, Configuration, Events, Remote Execution. Minions as inventory; grains as Facts; pillar as Configuration; events from event bus; salt commands as Remote Execution.

### 10.3.17 Chef / Cinc

Inventory, Facts, Configuration, Events, Reports. Nodes from Chef Server; ohai facts; node attributes / run list as Configuration; converge results as Reports/Events.

### 10.3.18 Capistrano / Deployer

Events, Deployment. Deploy events from log/audit sources.

### 10.3.19 Octopus Deploy

Events, Deployment. Deploy events; release/version data.

### 10.3.20 Jenkins / GitLab CI

Events, Deployment. Pipeline runs that produce node-affecting deployments are surfaced as Deployment events. Pipeline configuration management is out of scope.

## 10.4 Future-priority requirements

| ID | Requirement |
|----|-------------|
| `P2-FUT-001` | The platform **MUST NOT** assume any Priority 2 or Priority 3 integration's data model in cross-cutting platform code. All assumptions live in the integration's plugin. |
| `P2-FUT-002` | The matrix in [section 5](05-integration-matrix.md) **MUST** be amended whenever a Priority 2 or Priority 3 plugin's declared capabilities change. The matrix is the source of truth; any plugin that deviates is failing contract validation. |
| `P2-FUT-003` | The platform **MUST** allow Priority 2 and Priority 3 plugins to be sourced from community-distributed packages without modifying the core application. |

---

[← Previous: Priority 1b Integrations](09-priority-1b-integrations.md) | [Next: Platform Requirements →](11-platform-requirements.md)

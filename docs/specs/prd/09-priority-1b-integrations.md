# 9. Provisioning Integrations — Proxmox (Phase 1), AWS, Azure (Phase 2a)

This section covers the three provisioning-capable integrations. **Proxmox** is a Phase 1 integration, implemented after the core Phase 1 integrations (Puppet, Ansible, SSH, Bolt) are stable. **AWS and Azure** are deferred to Phase 2a (see [section 20](20-implementation-roadmap.md)). The specifications for all three are included here for reference; the phasing difference does not affect the plugin contract or the data model.

Each integration provides Inventory, Facts, and Provisioning — and each populates the journal from real-time API event queries against the underlying tool, not from local state inference.

## 9.1 Common requirements for cloud and hypervisor provisioning

| ID | Requirement |
|----|-------------|
| `PROV-COM-001` | Provisioning-capable plugins **MUST** populate the journal from real-time API queries against the upstream tool's event log, not from locally inferred state. |
| `PROV-COM-002` | Provisioning-capable plugins **MUST** report state transitions during a provisioning flow (pending → creating → running → ready) in real time to the user. |
| `PROV-COM-003` | Provisioning-capable plugins **MUST** ensure that newly created nodes appear in unified inventory within one inventory refresh cycle of the create operation completing. |
| `PROV-COM-004` | Provisioning-capable plugins **MUST** display resource discovery (templates, images, sizes, networks, regions) before the user submits a create request, with the available options refreshed against the source. |
| `PROV-COM-005` | Provisioning-capable plugins **MUST NOT** initiate billable cloud operations without prior RBAC and per-action permission checks. |
| `PROV-COM-006` | Provisioning-capable plugins **MUST** make every provisioning action attributable to the initiating user, captured in both the journal and the audit trail. |
| `PROV-COM-007` | Provisioning-capable plugins **MUST** apply per-integration concurrency limits to prevent overwhelming upstream APIs. |
| `PROV-COM-008` | Provisioning-capable plugins **MUST** distinguish "node managed by this integration" from "any node visible at the same identity" — destruction operations **MUST NOT** target a node the integration did not create or import as managed. |

## 9.2 Proxmox

Proxmox is the on-prem hypervisor target for Phase 1. It manages QEMU VMs and LXC containers in clustered or standalone deployments.

### 9.2.1 Capabilities provided

| Capability | Surface |
|------------|---------|
| Inventory | VMs, LXC containers, and hypervisor nodes from the Proxmox cluster API |
| Facts | Guest configuration and current resource usage |
| Provisioning | Create, destroy, and lifecycle operations on VMs and LXC containers |

The plugin **MUST NOT** declare Remote Execution, Configuration, Events, Monitoring, Reports, or Deployment capabilities.

#### Supplementary capabilities

In addition to its generic integration types, the Proxmox plugin declares the following supplementary capabilities (see [section 6.7](06-plugin-architecture.md#67-supplementary-capabilities-and-ui-extension-slots)):

| Capability ID | Slot | Description |
|---------------|------|-------------|
| `proxmox:snapshot_manager` | `node_tab` | View the snapshot tree for a VM or LXC container; create, revert to, and delete snapshots |
| `proxmox:console` | `node_action` | Launch a browser-based console session (noVNC or SPICE) for a running VM or LXC; opens in a new browser tab via a Proxmox-issued VNC proxy ticket |
| `proxmox:resource_topology` | `global_page` | Cluster-wide resource view: CPU, memory, and storage utilization per hypervisor node; guest distribution; HA group status |

Each supplementary capability is independently RBAC-gated and hidden entirely when the user lacks the required permission (`PLUG-806`).

### 9.2.2 Inventory

| ID | Requirement |
|----|-------------|
| `PROX-101` | The Proxmox plugin **MUST** retrieve the list of VMs and LXC containers across all cluster nodes via the Proxmox API. |
| `PROX-102` | The plugin **MUST** report per node: VM/LXC ID, name, type (qemu / lxc), status (running, stopped, paused, unknown), cluster node hosting the guest, allocated CPU and memory. |
| `PROX-103` | The plugin **MUST** present cluster nodes themselves as inventory items (the hypervisor hosts), distinguishable from guests. |
| `PROX-104` | Inventory **MUST** support pagination and **MUST** retrieve only the requested page from the Proxmox API where the API supports it. |
| `PROX-105` | The plugin **MUST** declare its identity confidence: VM/LXC IDs are stable within a cluster but not unique across clusters; guest hostname is best-effort and not always present. |

### 9.2.3 Facts

| ID | Requirement |
|----|-------------|
| `PROX-201` | The plugin **MUST** retrieve guest configuration: assigned CPU, memory, disk volumes (with sizes and storage backing), network interfaces (with bridge / VLAN / model), boot order, OS type. |
| `PROX-202` | The plugin **MUST** retrieve current resource usage: CPU usage, memory usage, disk I/O statistics, network throughput where the API exposes them. |
| `PROX-203` | Facts cache TTL default: 5 minutes for configuration data, 30 seconds for current usage. |

### 9.2.4 Provisioning

| ID | Requirement |
|----|-------------|
| `PROX-301` | The plugin **MUST** support VM creation from: template clones, ISO boot, and full clone of an existing VM. |
| `PROX-302` | The plugin **MUST** support LXC container creation from templates. |
| `PROX-303` | The plugin **MUST** support destruction of VMs and LXC containers. |
| `PROX-304` | The plugin **MUST** support lifecycle operations: start, stop, shutdown (graceful), reboot, suspend, resume. |
| `PROX-305` | Resource discovery **MUST** include: cluster nodes, storage pools (with available space), VM/LXC templates, ISO images, network bridges and VLANs. |
| `PROX-306` | The plugin **MUST** allow the user to choose the cluster node on which a VM/LXC is created. |
| `PROX-307` | Create operations **MUST** allow specification of: name, ID (auto or manual), CPU count, memory, disk size, storage backing, network interface configuration, boot device, OS type, cloud-init parameters where applicable. |
| `PROX-308` | The plugin **MUST** report task progress for long-running operations (clone, create) by polling Proxmox's task log. |

### 9.2.5 Snapshot management

Snapshots are a first-class Proxmox concept. Vigil surfaces the snapshot tree as a per-node tab and gates snapshot mutation actions with dedicated permissions, separate from general lifecycle operations.

| ID | Requirement |
|----|-------------|
| `PROX-701` | The plugin **MUST** retrieve the snapshot list per VM/LXC including: snapshot name, description, creation time, parent snapshot name (to reconstruct the tree), and whether RAM state was included. |
| `PROX-702` | The plugin **MUST** render the snapshot list as a tree, not a flat list, preserving the parent–child relationships recorded by Proxmox. |
| `PROX-703` | The plugin **MUST** support snapshot creation with: name (required), description (optional), RAM state inclusion flag. |
| `PROX-704` | The plugin **MUST** support revert-to-snapshot. Revert is a destructive operation — the UI **MUST** require explicit confirmation before submitting the request. The confirmation dialog **MUST** name the snapshot and state that current guest state will be overwritten. |
| `PROX-705` | The plugin **MUST** support snapshot deletion. Deletion of a snapshot that has children is subject to Proxmox's own constraint (children must be deleted first); the plugin **MUST** surface this constraint as an actionable error. |
| `PROX-706` | Snapshot create, revert, and delete operations **MUST** generate journal entries attributing the action to the initiating Vigil user. |
| `PROX-707` | The `proxmox:snapshot_manager` supplementary capability **MUST** be hidden (not greyed out) when the user lacks any of the required snapshot permissions. The tab renders only the operations the user holds permission for — a user with read-only snapshot permission sees the tree but no mutation actions. |

### 9.2.6 Console access

The Proxmox API issues short-lived VNC proxy tickets that allow direct browser console access to a running VM or LXC. Vigil brokers this ticket on behalf of the user but does not relay the console stream itself — the browser connects directly to Proxmox's VNC proxy endpoint.

| ID | Requirement |
|----|-------------|
| `PROX-801` | The plugin **MUST** support console access for running VMs and LXC containers via the Proxmox VNC proxy ticket API. |
| `PROX-802` | The console **MUST** open in a new browser tab, not in an inline frame within the Vigil application. This avoids cross-origin embedding complexity and keeps the noVNC/SPICE session's full viewport. |
| `PROX-803` | Vigil **MUST** obtain a fresh proxy ticket on each console launch. Tickets **MUST NOT** be cached or reused across sessions. |
| `PROX-804` | The console type (noVNC or SPICE) **MUST** follow the VM's configured display type. The plugin **MUST** prefer noVNC where both are available, for browser compatibility without a plugin. |
| `PROX-805` | The `proxmox:console` action **MUST** be visible only when the guest is in `running` state. The action **MUST** be absent (not disabled) when the guest is stopped, paused, or in an unknown state. |
| `PROX-806` | Console launch **MUST** generate an audit trail entry: which user launched a console session to which guest, at what time. Console sessions are privileged — they bypass OS-level access controls enforced by SSH or Ansible. The audit entry **MUST** note this explicitly. |
| `PROX-807` | The administration UI **MUST** document, adjacent to the `proxmox:vm:console` and `proxmox:lxc:console` permissions, that granting console access is equivalent to granting root-equivalent interactive access to the guest regardless of what other RBAC rules restrict. |

### 9.2.7 Journal

| ID | Requirement |
|----|-------------|
| `PROX-401` | The plugin **MUST** populate journal entries from the Proxmox cluster task log, retrieved via realtime API requests. The plugin **MUST NOT** synthesize journal entries solely from its own observed state changes. |
| `PROX-402` | Journal contributions include: VM/LXC create, destroy, start, stop, shutdown, reboot, suspend, resume, migrate, clone, snapshot, and any other lifecycle task type Proxmox records. |
| `PROX-403` | Each journal entry **MUST** carry: the upstream task identifier, initiating user (as recorded by Proxmox), result, duration. |

### 9.2.8 Authentication

| ID | Requirement |
|----|-------------|
| `PROX-501` | The plugin **MUST** support API token authentication (preferred) and ticket-based username/password authentication. |
| `PROX-502` | The plugin **MUST** verify TLS certificates by default. A skip-verify mode **MAY** be exposed for development with a clear warning. |
| `PROX-503` | Credentials **MUST** be handled through the platform's secrets-aware mechanism. |

### 9.2.9 Configuration schema

| Field | Required | Description |
|-------|----------|-------------|
| `endpoint` | yes | Proxmox API base URL (e.g., `https://pve:8006`) |
| `auth.method` | yes | `token` or `password` |
| `auth.token_id` / `auth.username` | conditional | Per method |
| `auth.token_secret` / `auth.password` | conditional | Per method (secret) |
| `realm` | no | Authentication realm (default `pam`) |
| `verify_tls` | no | Default true |
| `cluster_nodes` | no | Override list of cluster nodes (default: discovered) |
| `cache_ttl.*` | no | Per-capability TTL overrides |
| `concurrency` | no | Concurrent provisioning operations limit |

### 9.2.10 RBAC

| ID | Requirement |
|----|-------------|
| `PROX-601` | The Proxmox plugin's actions **MUST** be governed by platform RBAC. The following distinct permissions **MUST** exist: |
| `PROX-602` | — `proxmox:inventory:read` — view VMs, LXC containers, and hypervisor nodes |
| `PROX-603` | — `proxmox:facts:read` — view guest configuration and resource usage |
| `PROX-604` | — `proxmox:cluster:read` — view cluster-wide resource topology (required for `proxmox:resource_topology` supplementary capability) |
| `PROX-605` | — `proxmox:vm:create` — create VMs |
| `PROX-606` | — `proxmox:vm:destroy` — destroy VMs |
| `PROX-607` | — `proxmox:vm:start`, `proxmox:vm:stop`, `proxmox:vm:reboot`, `proxmox:vm:suspend`, `proxmox:vm:resume` — lifecycle operations on VMs |
| `PROX-608` | — `proxmox:vm:snapshot:read` — view snapshot tree |
| `PROX-609` | — `proxmox:vm:snapshot:create` — create snapshots |
| `PROX-610` | — `proxmox:vm:snapshot:revert` — revert to a snapshot (kept separate from create because revert is destructive) |
| `PROX-611` | — `proxmox:vm:snapshot:delete` — delete snapshots |
| `PROX-612` | — `proxmox:vm:console` — launch browser console (privileged — see `PROX-807`) |
| `PROX-613` | — `proxmox:lxc:create`, `proxmox:lxc:destroy`, `proxmox:lxc:start`, `proxmox:lxc:stop`, `proxmox:lxc:reboot`, `proxmox:lxc:suspend`, `proxmox:lxc:resume` |
| `PROX-614` | — `proxmox:lxc:snapshot:read`, `proxmox:lxc:snapshot:create`, `proxmox:lxc:snapshot:revert`, `proxmox:lxc:snapshot:delete` |
| `PROX-615` | — `proxmox:lxc:console` — launch browser console for LXC (same privilege warning as `PROX-807`) |
| `PROX-616` | Granular per-action and per-storage-pool permissions **MUST** be enforceable: a role may be restricted to create VMs only on specific storage pools or cluster nodes. |

## 9.3 AWS

AWS provisioning targets EC2 specifically. Other AWS services (RDS, S3, etc.) are out of scope for Phase 2a — they may appear in later priorities only when there is a node-level case for them.

### 9.3.1 Inventory

| ID | Requirement |
|----|-------------|
| `AWS-101` | The AWS plugin **MUST** retrieve EC2 instance lists across all configured regions via the AWS API. |
| `AWS-102` | The plugin **MUST** report per instance: instance ID, name (from `Name` tag), instance type, state (pending, running, stopping, stopped, terminated), region, availability zone, VPC, subnet, all tags. |
| `AWS-103` | The plugin **MUST** automatically derive groups from: region, VPC, and tags (configurable: which tag keys produce groups). |
| `AWS-104` | The plugin **MUST** declare identity confidence: instance ID is canonical and unique; private IPs are observable but not unique outside a VPC; public IPs are unstable across stop/start. |
| `AWS-105` | Inventory **MUST** support pagination via the AWS API's native paging tokens. |
| `AWS-106` | The plugin **MUST** support multiple AWS accounts as separate integrations and **MUST** support per-integration region scoping. |

### 9.3.2 Facts

| ID | Requirement |
|----|-------------|
| `AWS-201` | The plugin **MUST** retrieve per-instance facts: AMI ID, launch time, security groups, IAM instance profile, network interfaces (private and public IPs, ENIs, MAC), block device mappings, key pair, monitoring state, platform (Linux/Windows). |
| `AWS-202` | Facts cache TTL default: 5 minutes. |
| `AWS-203` | The plugin **MUST** include Auto Scaling Group membership where applicable (read-only attribute). |

### 9.3.3 Provisioning

| ID | Requirement |
|----|-------------|
| `AWS-301` | The plugin **MUST** support EC2 instance launch with the following parameters: AMI, instance type, VPC, subnet, security group(s), key pair, IAM instance profile, root volume size, additional tags, optional user-data. |
| `AWS-302` | The plugin **MUST** support instance termination. |
| `AWS-303` | The plugin **MUST** support lifecycle operations: start, stop, reboot, hibernate (where the instance is hibernation-capable). |
| `AWS-304` | Resource discovery **MUST** include: regions, instance types per region, AMIs (with filtering by owner, by name pattern, by architecture), VPCs per region, subnets per VPC, security groups per VPC, key pairs per region, IAM instance profiles. |
| `AWS-305` | The plugin **MUST** track create/terminate operations to completion and report instance state transitions in real time. |
| `AWS-306` | The plugin **MUST NOT** provide AMI authoring, key-pair generation, or VPC/subnet creation. Resource discovery is read-only. |

### 9.3.4 Journal

| ID | Requirement |
|----|-------------|
| `AWS-401` | The plugin **MUST** populate journal entries from CloudTrail events (or the equivalent EC2 lifecycle event source) retrieved via realtime API requests. |
| `AWS-402` | Journal entries **MUST** carry: AWS event ID, event time, the AWS-recorded actor (IAM user/role), event name, affected resource, result. |
| `AWS-403` | The plugin **SHOULD** correlate Vigil-initiated provisioning with the resulting CloudTrail event (e.g., by capturing the request ID at create time and linking it to the journal entry that materializes from the event log). |

### 9.3.5 Authentication

| ID | Requirement |
|----|-------------|
| `AWS-501` | The plugin **MUST** support standard AWS credential mechanisms: access key + secret, IAM role assumption, instance profile (when Vigil runs on EC2), AWS SSO. |
| `AWS-502` | The plugin **MUST** support cross-account role assumption with external ID. |
| `AWS-503` | Credentials **MUST** be handled through the platform's secrets-aware mechanism. |
| `AWS-504` | The plugin **MUST** declare in its administration UI which IAM permissions it requires for declared capabilities, so administrators can scope IAM policies appropriately. |

### 9.3.6 Configuration schema

| Field | Required | Description |
|-------|----------|-------------|
| `auth.method` | yes | `access_key`, `assume_role`, `instance_profile`, `sso` |
| `auth.access_key_id` / `auth.secret_access_key` | conditional | For access-key auth |
| `auth.role_arn` / `auth.external_id` | conditional | For role assumption |
| `auth.session_duration` | no | Override role-session duration |
| `regions` | yes | List of regions to monitor |
| `tag_groups` | no | Tag keys to expose as group dimensions |
| `cloudtrail.lookback` | no | How far back to query the event log on first sync |
| `cache_ttl.*` | no | Per-capability TTL overrides |
| `concurrency` | no | Concurrent API call limit |

### 9.3.7 RBAC

| ID | Requirement |
|----|-------------|
| `AWS-601` | Permissions: `aws:inventory:read`, `aws:facts:read`, `aws:ec2:launch`, `aws:ec2:terminate`, `aws:ec2:start`, `aws:ec2:stop`, `aws:ec2:reboot`, `aws:ec2:hibernate`. |
| `AWS-602` | Per-region and per-account scoping **MUST** be enforceable in role permissions. |
| `AWS-603` | Per-tag scoping **SHOULD** be enforceable (e.g., a role that may terminate instances tagged `env=dev` but not `env=prod`). |

## 9.4 Azure

Azure provisioning targets Virtual Machines specifically. Container Apps, AKS, App Services, and other higher-level services are out of scope for Phase 2a.

### 9.4.1 Inventory

| ID | Requirement |
|----|-------------|
| `AZ-101` | The Azure plugin **MUST** retrieve VM lists across all configured subscriptions via the Azure API. |
| `AZ-102` | The plugin **MUST** report per VM: VM ID (resource ID), name, location, resource group, size, all tags, power state, provisioning state. |
| `AZ-103` | The plugin **MUST** automatically derive groups from: location, resource group, and tags (configurable: which tag keys produce groups). |
| `AZ-104` | The plugin **MUST** declare identity confidence: VM resource ID is canonical and unique; computer name (from inside the OS) is best-effort. |
| `AZ-105` | Inventory **MUST** support pagination via the Azure API's native paging. |
| `AZ-106` | The plugin **MUST** support multiple subscriptions as separate integrations or as a single integration scoped to multiple subscriptions. |

### 9.4.2 Facts

| ID | Requirement |
|----|-------------|
| `AZ-201` | The plugin **MUST** retrieve per-VM facts: size, image reference, OS disk (size, storage account type), data disks, network interfaces (private and public IPs), availability set/zone, boot diagnostics state. |
| `AZ-202` | Facts cache TTL default: 5 minutes. |
| `AZ-203` | The plugin **MUST** include VMSS membership and identity assignments (system or user-assigned managed identity). |

### 9.4.3 Provisioning

| ID | Requirement |
|----|-------------|
| `AZ-301` | The plugin **MUST** support VM creation with: name, size, image, location, resource group, network configuration (VNet, subnet, public IP option), OS disk size, admin credential or SSH key. |
| `AZ-302` | The plugin **MUST** support lifecycle operations: start, stop (preserves billing), restart, deallocate (releases compute charge). |
| `AZ-303` | Resource discovery **MUST** include: locations, VM sizes per location, OS images (by publisher/offer/sku/version), resource groups, virtual networks, subnets. |
| `AZ-304` | The plugin **MUST** track long-running operations to completion and report state transitions. |
| `AZ-305` | The plugin **MUST NOT** provide creation of resource groups, VNets, subnets, custom images. Resource discovery is read-only. |

### 9.4.4 Journal

| ID | Requirement |
|----|-------------|
| `AZ-401` | The plugin **MUST** populate journal entries from the Azure Activity Log retrieved via realtime API requests. |
| `AZ-402` | Journal entries **MUST** carry: Azure correlation ID, event time, caller (Azure AD user/SPN), operation name, affected resource, result. |
| `AZ-403` | The plugin **SHOULD** correlate Vigil-initiated provisioning with the resulting Activity Log event by capturing the operation correlation ID. |

### 9.4.5 Authentication

| ID | Requirement |
|----|-------------|
| `AZ-501` | The plugin **MUST** support: service principal with secret, service principal with certificate, managed identity (when Vigil runs on Azure), Azure CLI fallback for local development. |
| `AZ-502` | The plugin **MUST** support multi-tenant configurations and explicit tenant ID. |
| `AZ-503` | Credentials **MUST** be handled through the platform's secrets-aware mechanism. |
| `AZ-504` | The plugin **MUST** declare the required RBAC roles or specific permissions for its capabilities, so administrators can scope Azure RBAC appropriately. |

### 9.4.6 Configuration schema

| Field | Required | Description |
|-------|----------|-------------|
| `auth.method` | yes | `service_principal_secret`, `service_principal_cert`, `managed_identity`, `cli` |
| `auth.tenant_id` | yes (for SPN) | |
| `auth.client_id` | yes (for SPN) | |
| `auth.client_secret` / `auth.cert_path` | conditional | (secret) |
| `subscriptions` | yes | List of subscription IDs |
| `tag_groups` | no | Tag keys to expose as group dimensions |
| `activity_log.lookback` | no | How far back to query the Activity Log on first sync |
| `cache_ttl.*` | no | Per-capability TTL overrides |
| `concurrency` | no | Concurrent API call limit |

### 9.4.7 RBAC

| ID | Requirement |
|----|-------------|
| `AZ-601` | Permissions: `azure:inventory:read`, `azure:facts:read`, `azure:vm:create`, `azure:vm:start`, `azure:vm:stop`, `azure:vm:restart`, `azure:vm:deallocate`. |
| `AZ-602` | Per-subscription and per-resource-group scoping **MUST** be enforceable. |
| `AZ-603` | Per-tag scoping **SHOULD** be enforceable. |

## 9.5 Acceptance criteria

Each provisioning integration is considered complete in its delivery phase when:

1. Each plugin populates unified inventory with VMs/instances and groups derived from native attributes.
2. Each plugin gathers facts from the upstream API with the documented field set.
3. Each plugin performs the documented lifecycle operations end-to-end, with state transitions reported in real time.
4. Resource discovery returns current options (templates / images / sizes / networks) on demand.
5. Each plugin populates the journal from real-time API event queries against the upstream tool.
6. Newly provisioned nodes appear in unified inventory within one refresh cycle.
7. Authentication mechanisms documented in each subsection work correctly, including credential rotation without restart.
8. RBAC permissions block unauthorized provisioning.
9. Per-integration concurrency limits prevent API rate-limit incidents.
10. Health checks distinguish authentication failure, network failure, and quota exhaustion as separate degradation modes.

---

[← Previous: Bolt, Ansible, SSH](08-priority-1-integrations.md) | [Next: P2/P3 Integrations →](10-priority-2-3-integrations.md)

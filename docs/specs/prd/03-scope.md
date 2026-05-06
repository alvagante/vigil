# 3. Scope Boundary

Vigil's scope is defined by a single, decisive question:

> **Is this feature about *what's happening on or to a node?***

If yes, it is in scope. If it is about *managing the underlying tool itself*, it is out of scope.

This section makes that boundary explicit and testable.

## 3.1 In scope

The system MUST provide the capabilities listed in this section. Capabilities listed elsewhere in the document are also in scope; this section enumerates the cross-cutting categories.

| ID | Requirement |
|----|-------------|
| `SCOPE-001` | The system **MUST** provide read access to node inventory aggregated across all enabled integrations. |
| `SCOPE-002` | The system **MUST** provide read access to facts (observed node attributes) per node. |
| `SCOPE-003` | The system **MUST** provide read access to desired-state configuration data (Hiera, catalogs, variables) per node. |
| `SCOPE-004` | The system **MUST** provide read access to events (state transitions) per node and globally. |
| `SCOPE-005` | The system **MUST** provide read access to current monitoring status per node and globally. |
| `SCOPE-006` | The system **MUST** provide read access to structured run reports per node and globally. |
| `SCOPE-007` | The system **MUST** provide remote execution of commands, tasks, and playbooks against nodes via execution-capable integrations. |
| `SCOPE-008` | The system **MUST** provide lifecycle management of VMs and containers via provisioning-capable integrations: create, destroy, start, stop, reboot, suspend, resume, deallocate. |
| `SCOPE-009` | The system **MUST** provide browse access to provisioning resource options (templates, images, sizes/flavors, networks, storage, regions). |
| `SCOPE-010` | The system **MUST** provide a unified, cross-tool node journal and global event timeline. |
| `SCOPE-011` | The system **MUST** provide read access to deployment events (application versions, deploy history) from deployment-aware integrations. |
| `SCOPE-012` | The system **MUST** enforce role-based access control over every capability listed in this section. |
| `SCOPE-013` | The system **MUST** provide r10k / Code Manager environment deployment operations as part of the Puppet integration. |
| `SCOPE-014` | The system **MUST** provide an MCP server exposing read-only infrastructure data to external AI agents. |

## 3.2 Out of scope

The following capabilities are explicitly out of scope. The system **MUST NOT** implement them, and they **MUST NOT** be added in a future phase without an explicit scope amendment.

| ID | Requirement |
|----|-------------|
| `SCOPE-101` | The system **MUST NOT** provide cloud billing, cost management, or budget alerting. |
| `SCOPE-102` | The system **MUST NOT** provide management of cloud or hypervisor storage pools as a primary feature. |
| `SCOPE-103` | The system **MUST NOT** provide network topology configuration (VPC creation, subnet design, route tables, firewall rule editing) as a primary feature. |
| `SCOPE-104` | The system **MUST NOT** provide editing of Puppet code, modules, manifests, or Hiera data files. |
| `SCOPE-105` | The system **MUST NOT** provide Puppet module management (install, upgrade, publish). |
| `SCOPE-106` | The system **MUST NOT** provide editing or creation of Ansible playbooks, roles, or modules. |
| `SCOPE-107` | The system **MUST NOT** provide Bolt task or plan authoring. |
| `SCOPE-108` | The system **MUST NOT** provide monitoring rule configuration (creating, editing, or removing checks; notification rules; escalation policies). |
| `SCOPE-109` | The system **MUST NOT** provide CI/CD pipeline management or deployment triggering. Deployment integrations are read-only. |
| `SCOPE-110` | The system **MUST NOT** provide management of Kubernetes pods, services, deployments, or higher-level workload primitives. Kubernetes integration is limited to node-level visibility. |
| `SCOPE-111` | The system **MUST NOT** store or compute infrastructure metrics. Metrics from monitoring integrations are read at query time. |
| `SCOPE-112` | The system **MUST NOT** function as an APM, log aggregation, or tracing backend. |
| `SCOPE-113` | The system **MUST NOT** provide configuration management primitives of its own (no "Vigil-native" desired state). |
| `SCOPE-114` | The system **MUST NOT** provide IAM management for cloud providers (no creating users, roles, policies in AWS/Azure/GCP). |

## 3.3 Marginal cases

When the scope of a feature is unclear, the following clarifications apply.

| ID | Clarification |
|----|---------------|
| `SCOPE-201` | **Read-only browsing of resource options** for provisioning (e.g., listing AWS AMIs, Azure VM sizes, Proxmox templates) is in scope; creating those resources is out of scope. |
| `SCOPE-202` | **Triggering an r10k / Code Manager environment deployment** is in scope (it's a Puppet operational task, not code editing). Editing the controlled repository is out of scope. |
| `SCOPE-203` | **Viewing a Kubernetes node's status, facts, and the workloads running on it** is in scope (node-level visibility). Creating a Deployment, exec'ing into a pod, or scaling a service is out of scope. |
| `SCOPE-204` | **Observing CI/CD-driven deployments** through their reported events is in scope. Triggering a CI pipeline run from within Vigil is out of scope. |
| `SCOPE-205` | **Manual journal notes** (user-authored timeline entries) are in scope. They are operator notes, not tool configuration. |
| `SCOPE-206` | **Restarting a service via remote execution** is in scope (it's a node action). Editing the service definition in Puppet/Ansible is out of scope. |
| `SCOPE-207` | **Running a vulnerability scanner's existing scan profile** against a node is in scope (it's an execution against the node). Authoring scan profiles is out of scope. |

## 3.4 Why these boundaries

A unified UI is only valuable if it stays focused. The boundaries above protect three properties:

- **Convergence integrity.** Vigil's value is that it shows what existing tools know. The moment Vigil owns infrastructure state, it becomes a fourth tool to manage — exactly the problem it's solving.
- **Replaceable tools.** When users can swap one Puppet for another, one Ansible for another, one cloud for another, Vigil's adoption is low-friction. Owning configuration would lock that out.
- **Operational clarity.** Operators expect tool consoles to remain authoritative for tool-specific concerns (rule editing, pipeline definition, code management). Vigil intervening would create competing sources of truth.

When a future request lands that strains these boundaries — and it will — the test is the same: *Is this about a node, or about the tool?* The answer determines the response.

---

[← Previous: Glossary](02-glossary.md) | [Next: Integration Types →](04-integration-types.md)

# 5. Integration Matrix

This section enumerates the integrations the system targets, organized by priority. The matrix shows which of the nine integration types each plugin provides. A check mark (`✓`) means the plugin **MUST** provide that type at the priority level indicated. A dash (`—`) means the type is intentionally not provided.

## 5.1 Priority and phasing

Priority levels reflect product order, not architectural distinction. All integrations — regardless of priority — implement the same plugin contract. There is no second-class plugin status.

| Priority | Phase | Description |
|----------|-------|-------------|
| **Priority 1 — Core** | Phase 1 | Minimum viable product. Implemented first. Defines the proof of the plugin contract. |
| **Priority 1b — Core (cloud / hypervisor)** | Phase 1b | Same priority level as core. Implemented after Phase 1 is solid, to keep early focus on the execution and Puppet stack. |
| **Priority 2 — Next phase** | Phase 2 | Targeted but not blocking initial release. Implemented after Priority 1 has stabilized and the platform contract has been validated. |
| **Priority 3 — Future / community-driven** | Phase 3+ | Backlog candidates. May be community-contributed. Specified at lower depth. |

| ID | Requirement |
|----|-------------|
| `MATRIX-001` | The system **MUST** ship Priority 1 integrations as part of the application distribution. |
| `MATRIX-002` | The system **MUST** treat Priority 1b integrations as ship-included once implemented; they are not separately distributable. |
| `MATRIX-003` | The system **MUST** support Priority 2 and Priority 3 integrations through the same plugin contract, distributable as packages or shipped with the application at the project's discretion. |
| `MATRIX-004` | The system **MUST NOT** specialize the runtime, configuration, or RBAC handling of any integration based on its priority level. |
| `MATRIX-005` | The matrix below **MUST** be authoritative for plugin capability declarations. A plugin **MUST NOT** declare capabilities not listed here without an explicit amendment to this document. |

## 5.2 Priority 1 — Core (Phase 1)

| Integration | Inv | Facts | Config | Events | Mon | Reports | Exec | Prov | Deploy |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **Puppet** (PuppetDB + Puppetserver + Hiera) | ✓ | ✓ | ✓ | ✓ | — | ✓ | — | — | — |
| **Bolt** | ✓ | — | — | — | — | — | ✓ | — | — |
| **Ansible** | ✓ | ✓ | — | — | — | — | ✓ | — | — |
| **SSH** | ✓ | ✓ | — | — | — | — | ✓ | — | — |

Detailed specifications: [07-puppet-integration.md](07-puppet-integration.md) and [08-priority-1-integrations.md](08-priority-1-integrations.md).

## 5.3 Priority 1b — Core cloud / hypervisor (Phase 1b)

| Integration | Inv | Facts | Config | Events | Mon | Reports | Exec | Prov | Deploy |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **Proxmox** | ✓ | ✓ | — | — | — | — | — | ✓ | — |
| **AWS** (EC2) | ✓ | ✓ | — | — | — | — | — | ✓ | — |
| **Azure** | ✓ | ✓ | — | — | — | — | — | ✓ | — |

Detailed specifications: [09-priority-1b-integrations.md](09-priority-1b-integrations.md).

## 5.4 Priority 2 — Next phase

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

Specifications (lighter-weight): [10-priority-2-3-integrations.md](10-priority-2-3-integrations.md).

## 5.5 Priority 3 — Future / community-driven

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

Specifications (high-level): [10-priority-2-3-integrations.md](10-priority-2-3-integrations.md).

## 5.6 Coverage summary

The following table aggregates the coverage of each integration type across all priorities, indicating how much choice the operator has at each level.

| Type | P1 / P1b plugins | P2 plugins | P3 plugins | Total |
|------|:-:|:-:|:-:|:-:|
| Inventory | 7 | 9 | 14 | 30 |
| Facts | 5 | 5 | 11 | 21 |
| Configuration | 1 | 2 | 3 | 6 |
| Events | 1 | 7 | 9 | 17 |
| Monitoring | 0 | 5 | 5 | 10 |
| Reports | 1 | 3 | 4 | 8 |
| Remote Execution | 3 | 1 | 2 | 6 |
| Provisioning | 3 | 3 | 4 | 10 |
| Deployment | 0 | 2 | 3 | 5 |

This is a working estimate; the authoritative count is the matrix above.

## 5.7 Integration count and platform implications

| ID | Requirement |
|----|-------------|
| `MATRIX-101` | The platform **MUST** support concurrent operation of all Priority 1 and Priority 1b integrations enabled simultaneously without exceeding platform-default resource budgets. |
| `MATRIX-102` | The platform **MUST** assume operators may enable any combination of Priority 2 and Priority 3 integrations and **MUST NOT** assume one integration's presence enables or disables another. |
| `MATRIX-103` | The platform **MUST** make a clear distinction in user-facing copy between *"this integration is not enabled"* and *"this integration is enabled but currently unhealthy."* The matrix above defines what is enable-able; runtime defines what is healthy. |

---

[← Previous: Integration Types](04-integration-types.md) | [Next: Plugin Architecture →](06-plugin-architecture.md)

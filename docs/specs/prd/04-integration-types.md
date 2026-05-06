# 4. Integration Types

The system organizes external tooling under **nine integration types**. Each type represents a fundamentally different interaction pattern: a different question being asked of the infrastructure, a different shape of answer, and a different cadence of refresh. A plugin declares which types it provides; the platform composes capabilities across plugins regardless of origin.

| # | Type | Core question | Direction | Mutability |
|---|------|---------------|-----------|------------|
| 1 | Inventory | Who exists? | Read | Read-only |
| 2 | Facts | What IS this node? | Read | Read-only |
| 3 | Configuration | What SHOULD this node be? | Read | Read-only |
| 4 | Events | What changed? | Read | Read-only |
| 5 | Monitoring | Is it healthy now? | Read | Read-only |
| 6 | Reports | How did a run go? | Read | Read-only |
| 7 | Remote Execution | Do something on it | Write | Action |
| 8 | Provisioning | Create / destroy / lifecycle | Write | Action |
| 9 | Deployment | What's running on it? | Read | Read-only |

The remainder of this section defines each type, the data it provides, the contract a plugin must honor when it declares the type, and the journal behavior it produces.

---

## 4.1 Inventory

**Question:** *Who exists?*

Inventory is the foundational type. It enumerates managed nodes — physical, virtual, or containerized — with enough identity and grouping information that the platform can deduplicate them across sources and present a unified estate.

| ID | Requirement |
|----|-------------|
| `TYPE-INV-001` | An Inventory-capable plugin **MUST** return a list of managed nodes with at minimum: a candidate identity (one or more of: hostname, certname, FQDN, primary IP), a status, and the integration source. |
| `TYPE-INV-002` | An Inventory-capable plugin **SHOULD** return group memberships per node where the underlying tool supports grouping. |
| `TYPE-INV-003` | An Inventory-capable plugin **MUST** support pagination for inventories larger than 200 nodes. |
| `TYPE-INV-004` | An Inventory-capable plugin **MUST** support a refresh operation that returns only nodes added, removed, or changed since a caller-supplied checkpoint, where the underlying tool supports incremental queries. |
| `TYPE-INV-005` | An Inventory-capable plugin **MUST** declare its node identity confidence (e.g., "certname is canonical and stable" vs. "FQDN is best-effort"). The platform uses this declaration when applying linking rules. |
| `TYPE-INV-006` | An Inventory-capable plugin **MUST NOT** modify upstream node records as a side effect of inventory queries. |

**Journal behavior:** Inventory data **MUST NOT** generate journal entries. Inventory is reference data, not events.

**Cacheability:** High. Inventory data is the canonical caching target with platform-default TTLs in the minutes-to-tens-of-minutes range.

---

## 4.2 Facts

**Question:** *What IS this node?*

Facts are observed, point-in-time attributes — descriptive truth about a node as seen by the source: OS, kernel, hardware, network interfaces, installed packages, uptime. Different sources may report overlapping or complementary facts, and the platform reconciles them.

| ID | Requirement |
|----|-------------|
| `TYPE-FACT-001` | A Facts-capable plugin **MUST** return facts as a structured key/value map per node, with nested values where appropriate. |
| `TYPE-FACT-002` | A Facts-capable plugin **MUST** include a "gathered at" timestamp per fact set. |
| `TYPE-FACT-003` | A Facts-capable plugin **MUST** support fact retrieval per node and **SHOULD** support batched retrieval for multiple nodes where the underlying tool allows. |
| `TYPE-FACT-004` | A Facts-capable plugin **MUST** declare which fact keys it provides authoritatively versus opportunistically, so the platform can resolve overlap deterministically. |
| `TYPE-FACT-005` | A Facts-capable plugin **MUST NOT** return facts that require write operations against the source as a side effect (e.g., no "trigger fact gathering" implicit in a read). |
| `TYPE-FACT-006` | The platform **MUST** present facts from multiple sources as merged data, with per-key source attribution shown on demand. |

**Journal behavior:** Facts **MUST NOT** generate journal entries on their own. Fact changes that the source surfaces as events feed the journal through the Events type.

**Cacheability:** High. Facts change slowly relative to UI page loads. Per-fact-set TTL is configurable per plugin.

---

## 4.3 Configuration

**Question:** *What SHOULD this node be?*

Configuration is the prescriptive counterpart of Facts. It describes what a node is configured to be — desired-state declarations, hierarchical data, compiled catalogs, class parameters, variables. It is the "should" against which facts are the "is."

| ID | Requirement |
|----|-------------|
| `TYPE-CFG-001` | A Configuration-capable plugin **MUST** return desired-state data scoped to a node, with structure preserved from the underlying source (hierarchy, nesting, parameter ownership). |
| `TYPE-CFG-002` | A Configuration-capable plugin **MUST** indicate the source level for each piece of configuration (e.g., for Hiera: which hierarchy level provided each value). |
| `TYPE-CFG-003` | A Configuration-capable plugin **MUST** support environment / scope qualification when the underlying tool supports it (e.g., per-environment Puppet catalogs). |
| `TYPE-CFG-004` | A Configuration-capable plugin **SHOULD** support comparison across environments (e.g., production vs. staging catalog diff). |
| `TYPE-CFG-005` | A Configuration-capable plugin **MUST NOT** mutate configuration as a side effect of read operations. |

**Journal behavior:** Configuration data **MUST NOT** generate journal entries. Changes to configuration that produce node-affecting events are captured by the Events type when a run executes.

**Cacheability:** Medium. Configuration changes more often than facts during code-deploy cycles but is not real-time. TTLs in the minutes range with manual invalidation hooks for Code Manager / r10k events.

---

## 4.4 Events

**Question:** *What changed?*

Events are discrete state transitions — a resource changed, a check transitioned state, an instance started, a deployment landed. Events are the primary feedstock of the journal.

| ID | Requirement |
|----|-------------|
| `TYPE-EVT-001` | An Events-capable plugin **MUST** return events as a time-ordered stream, each carrying a timestamp, source integration, target node, event type, and human-readable summary. |
| `TYPE-EVT-002` | An Events-capable plugin **MUST** include structured details (old value, new value, resource identifier, file/line references, containment paths) where the underlying source provides them. |
| `TYPE-EVT-003` | An Events-capable plugin **MUST** group events by their originating run or report when the underlying source defines such grouping (e.g., a single Puppet run that changes three resources produces three events grouped under one report). |
| `TYPE-EVT-004` | An Events-capable plugin **MUST NOT** surface no-op or unchanged events. The journal contains only state transitions. |
| `TYPE-EVT-005` | An Events-capable plugin **MUST** support time-range and per-node filtering at the source where the underlying tool allows. |
| `TYPE-EVT-006` | An Events-capable plugin **SHOULD** support push notification (webhook, message bus) when the underlying tool offers it; otherwise it **MUST** support polled discovery of new events. |

**Journal behavior:** Each event becomes one journal entry, attributed to its source integration, grouped under its originating run/report where applicable.

**Cacheability:** Low for recent events; high for historical events. The platform uses incremental fetching to avoid re-reading the full event log.

---

## 4.5 Monitoring

**Question:** *Is it healthy right now?*

Monitoring is the live-status type. It reports current check state, service state, metric values, and active alerts. Unlike Events, Monitoring is concerned with *steady state*, not transitions — though the *transitions* monitoring observes do feed the Events type.

| ID | Requirement |
|----|-------------|
| `TYPE-MON-001` | A Monitoring-capable plugin **MUST** return current health status per node: per-check state, service state, and a node-level rolled-up status. |
| `TYPE-MON-002` | A Monitoring-capable plugin **MUST** include the timestamp at which the source last evaluated the state. |
| `TYPE-MON-003` | A Monitoring-capable plugin **MUST** distinguish steady-state observations from state transitions. Only transitions feed the journal. |
| `TYPE-MON-004` | A Monitoring-capable plugin **SHOULD** support live updating: pushed updates if the source provides them, otherwise short-polling configurable per integration. |
| `TYPE-MON-005` | A Monitoring-capable plugin **MUST** return active alerts with severity, originating check, and acknowledgement state where applicable. |
| `TYPE-MON-006` | A Monitoring-capable plugin **MUST NOT** acknowledge, modify, or silence alerts as a side effect of read operations. |

**Journal behavior:** Steady-state monitoring **MUST NOT** generate journal entries. State *changes* (OK→CRITICAL, CRITICAL→OK, WARNING→OK, etc.) **MUST** generate one journal entry per transition.

**Cacheability:** Very short. Monitoring is the most time-sensitive type. Cache TTL is in seconds, with live-update preferred where supported.

---

## 4.6 Reports

**Question:** *How did a run go?*

Reports are richer than individual events — they represent the complete result of a run or scan, with summary metrics, logs, resource-level detail, and timing breakdowns. A Puppet run produces one report; a vulnerability scan produces one report. Reports may produce multiple Events.

| ID | Requirement |
|----|-------------|
| `TYPE-RPT-001` | A Reports-capable plugin **MUST** return reports as structured records containing: run identifier, target node, start/end timestamps, summary metrics, and resource-level (or finding-level) details. |
| `TYPE-RPT-002` | A Reports-capable plugin **MUST** include log entries with severity level, source, and tags where the underlying source provides them. |
| `TYPE-RPT-003` | A Reports-capable plugin **MUST** indicate whether a run was in noop / dry-run mode where applicable. |
| `TYPE-RPT-004` | A Reports-capable plugin **MUST** provide drill-down from summary to per-resource (or per-finding) detail. |
| `TYPE-RPT-005` | A Reports-capable plugin **MUST** support report retrieval per node, per group, and globally with time-range and status filters. |
| `TYPE-RPT-006` | A Reports-capable plugin **SHOULD** provide phase-level timing breakdown where the source captures it (e.g., Puppet's facts/catalog/apply phases). |

**Journal behavior:** Events extracted from reports feed the journal. The report itself is referenced from each derived journal entry. Reports with no extractable change events (no-op runs) **MUST NOT** generate journal entries.

**Cacheability:** High for completed reports (immutable). Recent reports may need short TTLs to surface newly arrived runs promptly.

---

## 4.7 Remote Execution

**Question:** *Do something on it.*

Remote Execution is the first write-side type. It runs commands, tasks, scripts, or playbooks against target nodes, with streaming output and full transcript preservation. Targets may be a single node, a group, or an ad-hoc list.

| ID | Requirement |
|----|-------------|
| `TYPE-EXEC-001` | A Remote-Execution-capable plugin **MUST** accept a target specification (node, group, or list), an executable artifact (command, task, playbook), and parameters. |
| `TYPE-EXEC-002` | A Remote-Execution-capable plugin **MUST** stream stdout and stderr in real time, with per-target attribution when executing against multiple nodes. |
| `TYPE-EXEC-003` | A Remote-Execution-capable plugin **MUST** capture and persist the full transcript (stdout, stderr, exit status, duration, target list, parameters, initiating user) for retrieval after the stream ends. |
| `TYPE-EXEC-004` | A Remote-Execution-capable plugin **MUST** support automatic discovery of available tasks/playbooks and their parameter metadata where the underlying tool supports introspection. |
| `TYPE-EXEC-005` | A Remote-Execution-capable plugin **MUST** enforce platform-level concurrency limits and **MUST** apply per-execution timeouts (wall-clock and idle). |
| `TYPE-EXEC-006` | A Remote-Execution-capable plugin **MUST** make every execution attributable to the initiating user. |
| `TYPE-EXEC-007` | A Remote-Execution-capable plugin **MUST NOT** execute commands that have not passed platform-level security controls (allowlist, RBAC, granular per-action permission). |

**Journal behavior:** Each execution **MUST** generate one journal entry per target node, summarizing the action and exit status, linking back to the full transcript.

**Cacheability:** None for live executions. Historical executions are immutable and retrievable indefinitely.

---

## 4.8 Provisioning

**Question:** *Create, destroy, or change a node's lifecycle.*

Provisioning is the second write-side type. It manages VM and container lifecycles — create, destroy, start, stop, reboot, suspend, resume, deallocate — and discovers the resources that provisioning operations need (templates, images, sizes, networks, regions).

| ID | Requirement |
|----|-------------|
| `TYPE-PROV-001` | A Provisioning-capable plugin **MUST** support at minimum: create, destroy, start, stop. It **SHOULD** support reboot. It **MAY** support suspend, resume, deallocate. |
| `TYPE-PROV-002` | A Provisioning-capable plugin **MUST** expose a discovery interface returning: available templates/images, sizes/flavors, networks/subnets, storage options, and regions/locations as applicable to the underlying tool. |
| `TYPE-PROV-003` | A Provisioning-capable plugin **MUST** report provisioning progress (state transitions: pending → creating → running → ready) in real time. |
| `TYPE-PROV-004` | A Provisioning-capable plugin **MUST** populate the journal with lifecycle events sourced from real-time API queries against the underlying tool, not from locally inferred state, when the underlying tool exposes such an event log. |
| `TYPE-PROV-005` | A Provisioning-capable plugin **MUST** make every provisioning action attributable to the initiating user. |
| `TYPE-PROV-006` | A Provisioning-capable plugin **MUST NOT** initiate billable cloud resource creation without passing platform-level RBAC and per-action permission checks. |
| `TYPE-PROV-007` | A Provisioning-capable plugin **MUST** ensure that newly provisioned nodes appear in the unified inventory within one inventory refresh cycle of completion. |

**Journal behavior:** Each provisioning lifecycle action **MUST** generate one journal entry. For cloud and hypervisor provisioning, lifecycle events from the source's API event log **MUST** populate the journal in real time, not from local state inference.

**Cacheability:** Discovery data (templates, sizes, regions) is highly cacheable with TTLs in the hours range. Lifecycle state of an individual node is fetched fresh on demand.

---

## 4.9 Deployment

**Question:** *What's running on it?*

Deployment is read-only visibility into application releases on a node — what version of what application was deployed when, by whom, with what result. Vigil does not perform deployments; it observes them.

| ID | Requirement |
|----|-------------|
| `TYPE-DEPL-001` | A Deployment-capable plugin **MUST** return deployment events per node: application identifier, version, deploy timestamp, initiating actor (where known), and deployment status. |
| `TYPE-DEPL-002` | A Deployment-capable plugin **MUST** support per-node deployment history retrieval. |
| `TYPE-DEPL-003` | A Deployment-capable plugin **MUST** indicate the deployment source tool (e.g., ArgoCD, Jenkins, Capistrano) so the journal entry attribution is clear. |
| `TYPE-DEPL-004` | A Deployment-capable plugin **MUST NOT** trigger, retry, roll back, or otherwise modify deployments. |

**Journal behavior:** Each deployment event **MUST** generate one journal entry, attributed to the deployment source tool.

**Cacheability:** High for historical events; medium for the most recent. Live update via push is preferred where supported.

---

## 4.10 Journal behavior summary

The following table summarizes how each type contributes to the journal. It restates rules defined above for quick reference.

| Type | Journal contribution |
|------|----------------------|
| Inventory | None |
| Facts | None |
| Configuration | None |
| Events | One journal entry per event |
| Monitoring | One entry per state *change* (not per check evaluation) |
| Reports | One entry per change event extracted from the report; no entries for no-op runs |
| Remote Execution | One entry per execution, per target |
| Provisioning | One entry per lifecycle action; sourced from real-time API events for cloud/hypervisor |
| Deployment | One entry per deploy event |

| ID | Requirement |
|----|-------------|
| `TYPE-JRN-001` | The platform **MUST** apply the journal contribution rules in section 4.10 uniformly across all integrations of a given type. |
| `TYPE-JRN-002` | The platform **MUST NOT** synthesize journal entries for steady-state observations of any type. |
| `TYPE-JRN-003` | The platform **MUST** preserve grouping relationships between entries derived from the same originating artifact (e.g., events from a single report remain grouped under that report in the journal UI). |

---

[← Previous: Scope](03-scope.md) | [Next: Integration Matrix →](05-integration-matrix.md)

# 12. Core Data Model

This section defines the **conceptual** data model — the entities and relationships every feature in the system is built around. It is not a database schema, not a serialization format, not an API specification. It is the vocabulary the rest of the document uses.

The model is implementation-agnostic. Storage, indexing, denormalization, and query strategy are not specified here.

## 12.1 Core entities

### 12.1.1 Node

A managed server, virtual machine, or container.

| Property | Description |
|----------|-------------|
| Canonical identity | Resolved from candidate identity attributes (certname, FQDN, hostname, primary IP) per linking rules |
| Identity attributes | All known identity values from all contributing sources |
| Source set | The integrations that report this node |
| Status | Per-source status, plus a derived overall status |
| Group memberships | Per-source groups; merged group view |
| Created | First time the node appeared in any source |
| Last seen | Latest contact time across sources |

A Node is the atomic unit of the domain model. Every other entity except User and Role is associated with at least one Node.

| ID | Requirement |
|----|-------------|
| `DM-001` | A Node **MUST** have a stable canonical identity. The platform **MUST NOT** lose track of a Node when one of its identity attributes changes (e.g., IP rotation), provided another stable attribute (certname, hostname) persists. |
| `DM-002` | A Node **MUST** retain attribution from every source that reports it. Removing a Node from one source **MUST NOT** remove it from inventory if another source still reports it; only the source attribution is updated. |
| `DM-003` | A Node **MUST** be presentable as a single inventory entry to users, with the per-source view available on demand. |

### 12.1.2 Integration

A configured connection to an external tool.

| Property | Description |
|----------|-------------|
| Plugin identifier | Which plugin provides this integration (e.g., `puppet`, `aws`) |
| Integration identifier | Stable per-instance identifier (e.g., `puppet-prod`, `aws-account-9876`) |
| Configuration | The instance-specific settings |
| Declared types | Which integration types this instance provides |
| Health | Per-capability health, last call timestamps, recent error |
| Status | Enabled / disabled |

| ID | Requirement |
|----|-------------|
| `DM-101` | An Integration **MUST** be uniquely identifiable across the platform by its Integration identifier. |
| `DM-102` | An Integration **MUST** carry the same set of declared types its plugin declares. The platform **MUST** reject configurations that ask for capabilities the plugin does not declare. |
| `DM-103` | A single plugin **MAY** be instantiated as multiple integrations with different configurations (e.g., two Ansible projects, three AWS accounts). Each instantiation **MUST** be independently configurable, enable-able, and observable. |

### 12.1.3 Group

A named collection of nodes.

| Property | Description |
|----------|-------------|
| Name | Group label as it appears in the source(s) |
| Source set | Integrations that contribute this group |
| Membership | Set of Nodes belonging to this group, merged across sources |
| Hierarchy | Parent / child relationships (per source) |
| Metadata | Source-specific attributes (Ansible group_vars, AWS tag values, Puppet inventory facts) |

| ID | Requirement |
|----|-------------|
| `DM-201` | Groups with matching names across sources **MUST** be linkable per [section 11.1.4](11-platform-requirements.md#114-group-linking). |
| `DM-202` | A Group's membership **MUST** be derived dynamically from the contributing sources at query time. The platform **MUST NOT** maintain a denormalized group-membership table that requires write-side propagation. |

### 12.1.4 User

An authenticated person or service account.

| Property | Description |
|----------|-------------|
| Identifier | Stable per-user identifier |
| Authentication source | Local or external (per IdP) |
| Display name, email | For UI |
| Roles | Direct assignments + group-mapped assignments |
| Status | Active / disabled |
| Tokens | Issued API tokens (with own scopes / lifetimes) |

| ID | Requirement |
|----|-------------|
| `DM-301` | A User's effective permissions **MUST** be the union of permissions across all assigned roles, regardless of assignment source. |
| `DM-302` | A User externally authenticated via an IdP **MUST NOT** have a usable local password. |
| `DM-303` | A User's identity **MUST** persist across IdP logins — group membership changes update the user's effective roles, not the user's identity. |

### 12.1.5 Role

A named set of permissions.

| Property | Description |
|----------|-------------|
| Name | Human-readable role name |
| Permissions | Set of permission specifications (action, integration scope, target scope) |
| Description | Administrator-supplied description |

| ID | Requirement |
|----|-------------|
| `DM-401` | A Role's permission set **MUST** be modifiable; modifications take effect on the next permission evaluation per user. |
| `DM-402` | A Role **MUST** be deletable if it has no current users assigned. The platform **MUST** prevent deletion if assigned and **MUST** offer a "force delete" only with explicit confirmation. |

### 12.1.6 Journal Entry

A single significant event in a Node's history.

| Property | Description |
|----------|-------------|
| Identifier | Stable per-entry identifier (the originating source's event ID where one exists) |
| Node | The Node this entry belongs to |
| Timestamp | When the event occurred (per the source) |
| Source integration | Which Integration produced this entry |
| Type | The kind of event (provisioning, execution, monitoring transition, deployment, manual note, configuration change) |
| Summary | Short human-readable description |
| Severity | Informational, notice, warning, error |
| Structured details | Optional structured payload appropriate to the type |
| Source artifact reference | Optional link to an originating Report, Execution, or remote system record |
| Group key | Optional grouping key (e.g., a Puppet report ID for events from the same run) |

| ID | Requirement |
|----|-------------|
| `DM-501` | A Journal Entry **MUST NOT** be modifiable except for manual notes by their author. |
| `DM-502` | A Journal Entry **MUST** carry source attribution. |
| `DM-503` | A Journal Entry's group key **MUST** preserve the source's grouping intent — events from one Puppet run share the same group key. |

### 12.1.7 Execution

An Execution record represents a single command, task, plan, or playbook run against **one Node**. One user action targeting N nodes creates N Execution records, each self-contained. Records spawned by the same dispatch share an **Execution Group** identifier.

| Property | Description |
|----------|-------------|
| Identifier | Stable per-record identifier (unique per node per run) |
| Execution group | Optional stable ID shared by all records from the same dispatch; single-node actions still have a group (with one member) |
| Initiating user | The User who submitted the dispatch |
| Integration | The integration that performed the execution |
| Target node | The single Node this record concerns |
| Artifact | Command, task, plan, or playbook name + parameters (identical across group members) |
| Start, end | Timestamps (may vary per node within a group) |
| Outcome | `ok`, `changed`, `failed`, `timed_out`, `unreachable`, `permission_denied` |
| Transcript | stdout + stderr with per-line timestamps; size-capped (see `DM-604`) |
| Streaming state | `live` while output is in flight; `closed` once the process exits or times out |

| ID | Requirement |
|----|-------------|
| `DM-601` | One Execution record **MUST** be created per target Node that was **actually dispatched** to an integration. Nodes denied by RBAC before dispatch **MUST NOT** produce Execution records — the denial is recorded in the audit trail (`RBAC-109`), not in the execution model. One dispatch against N nodes where 2 are denied creates N−2 Execution records. |
| `DM-601a` | All records from the same dispatch **MUST** share an `execution_group_id`. A single-node dispatch still produces a group (of one). The group is the stable reference for "I ran this action." The group contains only dispatched nodes; the audit trail is the authoritative record of denied nodes. |
| `DM-602` | Each Execution record's transcript **MUST** be retrievable indefinitely, subject to the configured retention policy. |
| `DM-603` | Re-execution from history **MUST** be supported at two scopes: re-run this record's node only; re-run the entire group against all original nodes. The UI **MUST** also allow re-running only the failed members of a group (outcome ≠ `ok`). |
| `DM-604` | Transcripts **MUST** be stored inline with a configurable per-record size cap (default: 50 MB). When a transcript reaches the cap, the plugin **MUST** close the transcript with an explicit truncation marker and the total bytes written before truncation. The record is still saved; truncation is not an error. |
| `DM-605` | The execution list view **MUST** group by `execution_group_id` by default, showing a summary row per group: artifact name, initiating user, start time, and aggregate outcome counts (e.g., `47 ok / 2 failed / 1 unreachable`). Expanding a group reveals the per-node records. |
| `DM-606` | An Execution record **MUST** generate exactly one Journal Entry for its target Node. The 1:1 relationship is a direct consequence of the per-node record model. |

### 12.1.8 Report

A structured result of a completed run or scan (e.g., Puppet run report, vulnerability scan report).

| Property | Description |
|----------|-------------|
| Identifier | Source-assigned identifier |
| Node | The Node this report concerns |
| Source integration | Which Integration produced this Report |
| Start, end | Timestamps |
| Summary metrics | Counts, durations, status |
| Phase timings | Where applicable |
| Resource / finding entries | Drill-down detail |
| Mode | Normal / noop / dry-run / etc. |
| Environment / scope | Where applicable |

| ID | Requirement |
|----|-------------|
| `DM-701` | A Report **MUST** belong to exactly one Node. |
| `DM-702` | A Report **MAY** produce zero or more Journal Entries via event extraction. The link from each Entry to its source Report **MUST** be preserved. |
| `DM-703` | A Report's content **MUST** be retrievable indefinitely (subject to retention policy). |

### 12.1.9 Fact

A key-value attribute of a Node, observed at a point in time.

| Property | Description |
|----------|-------------|
| Node | The Node this fact concerns |
| Key | Fact name (potentially nested, e.g., `os.distro.codename`) |
| Value | Scalar, structured, or hierarchical |
| Source integration | Which Integration reported this fact |
| Gathered at | When the source observed it |
| Authority | Whether the source declared itself authoritative or opportunistic for this key |

| ID | Requirement |
|----|-------------|
| `DM-801` | A Node **MAY** have multiple values for the same fact key, contributed by different sources. The platform **MUST** retain all values with attribution. |
| `DM-802` | The platform **MUST** present a reconciled value per fact key by default, choosing the authoritative source where one exists, else the most recently gathered. |

### 12.1.10 Configuration Item

A desired-state declaration scoped to a Node.

| Property | Description |
|----------|-------------|
| Node | The Node this item concerns |
| Source integration | Which Integration produced this item |
| Scope | Hiera level, catalog resource, Ansible variable, etc. |
| Key / identifier | The name of the configuration item |
| Value | The declared value |
| Provenance | The hierarchy level / file / scope chain |

| ID | Requirement |
|----|-------------|
| `DM-901` | A Configuration Item **MUST** retain its source's provenance — for Hiera items, which level provided the value; for catalog resources, the file/line of declaration. |
| `DM-902` | A Configuration Item **MUST** be scoped — Hiera values are scoped by environment; catalog resources by environment and catalog version. |

## 12.2 Key relationships

The following list enumerates the principal relationships among entities. Cardinalities use the notation `[min..max]`.

| From | Relationship | To | Cardinality |
|------|--------------|-----|-------------|
| Node | is known by | Integration | [1..n] |
| Node | belongs to | Group | [0..n] |
| Node | has | Fact | [0..n] |
| Node | has | Configuration Item | [0..n] |
| Node | has | Journal Entry | [0..n] |
| Node | has | Report | [0..n] |
| Group | contains | Node | [1..n] |
| Group | originates from | Integration | [1..n] |
| User | has | Role | [1..n] |
| User | initiates | Execution | [0..n] |
| Execution | targets | Node | [1..1] (one record per node) |
| Execution | belongs to | Execution Group | [1..1] |
| Execution Group | contains | Execution | [1..n] |
| Execution | uses | Integration | [1..1] |
| Execution | produces | Journal Entry | [1..1] |
| Report | belongs to | Node | [1..1] |
| Report | produces | Journal Entry | [0..n] |
| Journal Entry | references | Report or Execution | [0..1] |
| Role | grants | Permission | [1..n] |
| Integration | provides | Capability | [1..9] |

## 12.3 Identity, scope, and source attribution

| ID | Requirement |
|----|-------------|
| `DM-1001` | Every record produced by an Integration **MUST** carry source attribution: at minimum the Integration identifier and capture timestamp. |
| `DM-1002` | The platform **MUST** preserve source attribution through aggregation, deduplication, caching, and presentation. |
| `DM-1003` | Per-record attribution **MUST** survive plugin upgrade and configuration change as long as the Integration's identifier remains stable. |
| `DM-1004` | The platform **MUST** support time-bounded views — the user **MUST** be able to ask "what did this Node look like on 2026-04-15?" by walking historical journal entries, reports, and (where stored) historical fact snapshots. |

## 12.4 Data lifecycle

Vigil uses a **hybrid persistence model**. Node *identity* is persisted by the platform; node *data* is derived from external tools on demand. The distinction is load-bearing: it is what makes stable Journal references, manual linking overrides, and explicit decommission possible while keeping the external tool as the authoritative source of truth for everything operational.

### 12.4.1 Derived data (source tools are authoritative)

| ID | Requirement |
|----|-------------|
| `DM-1101` | Node **data** — Facts, Configuration, Monitoring state, Reports, Provisioning lifecycle events, Deployment events, and inventory membership (which nodes a source currently reports) — is **derived**. The platform queries these from the source tool on demand and caches them short-term. Vigil does not store them authoritatively. The source tool is the single source of truth for all derived data. |
| `DM-1101a` | When a source tool stops reporting a node (because the node was decommissioned or removed from inventory), the derived data for that node becomes stale and is eventually evicted from cache. The node's identity record in Vigil is **not** removed automatically; it is marked as **unreported**. |

### 12.4.2 Persisted data (Vigil is authoritative)

| ID | Requirement |
|----|-------------|
| `DM-1102` | Node **identity records** — canonical identifier, known identity attributes (certname, FQDN, hostname, IPs) per source, source set, linking metadata, manual link/unlink overrides, decommission flag, and first-seen / last-seen timestamps — **MUST** be persisted by the platform in its primary data store. These records are what make stable Journal and Execution references possible, and what survive the temporary or permanent disappearance of a source. |
| `DM-1103` | Execution transcripts and manual journal notes **MUST** be persisted by the platform, as Vigil is the originating source. Configurable retention policy applies. |
| `DM-1104` | The audit trail **MUST** be persisted independently of journal data, with its own retention policy. |
| `DM-1105` | The platform **MUST NOT** auto-delete persisted data without explicit retention policy expiration. Manual purge is administrator-only. |

### 12.4.3 Node lifecycle states

A node identity record transitions through the following states:

| State | Meaning |
|-------|---------|
| **Active** | At least one integration currently reports this node. |
| **Unreported** | No integration currently reports this node; it was previously active. Derived data is stale or absent. The identity record is retained. |
| **Decommissioned** | An administrator has explicitly marked the node as decommissioned. The record is tombstoned: it is removed from the active inventory view, its IP and identity claims are released (allowing re-linking to a new node at the same address), and it is retained for historical Journal and Execution references. |

| ID | Requirement |
|----|-------------|
| `DM-1106` | The platform **MUST** provide an explicit **decommission** action, administrator-only, that transitions a node from Unreported (or Active) to Decommissioned. |
| `DM-1107` | Decommissioning a node **MUST** release all identity claims (including IP) so that a new node subsequently reported at the same address is linked fresh rather than merged into the decommissioned record. |
| `DM-1108` | A decommissioned node **MUST** remain reachable from Vigil-originated Journal entries (executions, manual notes) and Execution history that reference it, presented with a clear decommission marker. External journal events (from integrations) are available only for as long as the upstream source retains them — Vigil does not archive external events on decommission (see `JRN-202`). The UI **MUST** display a notice on the decommissioned node's journal page stating that external event history depends on source retention. |
| `DM-1109` | The platform **MUST** surface Unreported nodes to administrators in a dedicated view, showing when each node was last seen and by which integration, so administrators can act on them (decommission, investigate, or wait for the source to recover). |

## 12.5 Conceptual diagram

The diagram below uses ASCII to express the principal relationships. Boxes are entities; arrows show "X belongs to / produces / has Y."

```
+---------+         +-------------+         +----------+
|  User   |---has-->|    Role     |--grants->|Permission|
+---------+         +-------------+         +----------+
     |
   initiates
     v
+-----------+        +---------------+        +--------+
| Execution |--targets->|     Node      |<--reports--|Integ.|
+-----------+        +---------------+        +--------+
     |                  |    |    |
   produces            has  has  has
     v                  v    v    v
+-----------+      +-----+ +----+ +------+
| Journal E.|<-extr|Repor|| Fact|| Config|
+-----------+      +-----+ +----+ +------+
                       |
                  produces
                       v
                  (extracted Journal Entries, grouped by Report)
```

The diagram is illustrative; the authoritative relationships are the table in [section 12.2](#122-key-relationships).

---

[← Previous: Platform Requirements](11-platform-requirements.md) | [Next: User Flows →](13-user-flows.md)

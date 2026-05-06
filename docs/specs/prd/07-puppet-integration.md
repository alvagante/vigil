# 7. Puppet Integration — Detailed Specification

Puppet is Vigil's most important integration. It is the single most feature-rich plugin and the deepest source of node truth. The specification below is intentionally more detailed than for any other integration because Puppet exposes more capability surface than any other tool Vigil targets, and because it pulls together three sub-systems — PuppetDB, Puppetserver, and Hiera — under one plugin.

The Puppet integration **MUST** support both **Puppet Enterprise** and **Open Source Puppet / OpenVox**.

## 7.1 Sub-systems

The Puppet plugin connects to three sub-systems. They may be configured independently or as a coordinated set.

| Sub-system | Role |
|------------|------|
| **PuppetDB** | Authoritative store of node identity, facts, catalogs, reports, and resource events. Read-heavy. PQL is the query language. |
| **Puppetserver** | Compiles catalogs, signs certificates, manages environments, hosts Code Manager / r10k orchestration endpoints. |
| **Hiera (local control-repo)** | Hierarchical configuration data layer. Read from a local copy of the control-repo (Puppetserver's API does not expose Hiera data). The control-repo path is configurable per integration. |

| ID | Requirement |
|----|-------------|
| `PUP-001` | The Puppet plugin **MUST** support PuppetDB and Puppetserver as separately configured endpoints. They **MAY** point at the same host or different hosts. |
| `PUP-002` | The Puppet plugin **MUST** function with PuppetDB only (no Puppetserver) for a degraded read-only deployment, exposing only the capabilities PuppetDB serves (Inventory, Facts, Events, Reports). |
| `PUP-003` | The Puppet plugin **MUST** function with Puppetserver only (no PuppetDB) for a degraded compile-only deployment, exposing only Configuration capabilities (catalog compilation, environment operations). Hiera browsing remains available independently as it reads from the local control-repo. |
| `PUP-004` | The Puppet plugin **MUST** detect whether the deployment is Puppet Enterprise or Open Source / OpenVox and adapt API path conventions and authentication mechanisms accordingly. |

## 7.2 Capabilities provided

Per the [integration matrix](05-integration-matrix.md), the Puppet plugin provides:

| Capability | Surface |
|------------|---------|
| Inventory | Nodes from PuppetDB certnames + Puppetserver CA |
| Facts | Full structured facts from PuppetDB |
| Configuration | Hiera, compiled catalogs, environment management |
| Events | Resource-level change events from reports |
| Reports | Full Puppet run reports with metrics, logs, drill-down |

The plugin **MUST NOT** declare Monitoring, Remote Execution, Provisioning, or Deployment capabilities. (Bolt, a sibling integration, provides Remote Execution against Puppet-managed nodes; the two must not be conflated.)

## 7.3 Inventory

| ID | Requirement |
|----|-------------|
| `PUP-101` | The Puppet plugin **MUST** retrieve node lists from PuppetDB by querying certnames with status: active, deactivated, expired. |
| `PUP-102` | The Puppet plugin **MUST** also retrieve the Puppetserver CA certificate list, including signed, requested (pending signing), and revoked certificates, when Puppetserver is configured. |
| `PUP-103` | The Puppet plugin **MUST** present a node's PuppetDB certname status and Puppetserver CA status as separate attributes — the same node **MAY** be active in PuppetDB and revoked in CA, and the user **MUST** see both. |
| `PUP-104` | Inventory queries to PuppetDB **MUST** use PQL for server-side filtering (status, environment, fact-based filtering, group membership). The plugin **MUST NOT** materialize the full PuppetDB node set client-side for filterable queries. |
| `PUP-105` | The Puppet plugin **MUST** support pagination of inventory results, with the page size configurable. |
| `PUP-106` | The Puppet plugin **MUST** declare its identity confidence as: certname is canonical and stable; FQDN is best-effort; primary IP is observed and may shift. |
| `PUP-107` | Deactivated and expired nodes **MUST** be retained in inventory with a clear marker, configurable per integration to be hidden from default views. |

## 7.4 Facts

| ID | Requirement |
|----|-------------|
| `PUP-201` | The Puppet plugin **MUST** retrieve full structured facts per node from PuppetDB, including standard facts (OS, kernel, hardware, network) and any custom facts the site uses. |
| `PUP-202` | The Puppet plugin **MUST** preserve the structure of facts (nested objects, arrays) as they appear in PuppetDB. |
| `PUP-203` | The Puppet plugin **MUST** include a per-fact-set "gathered at" timestamp from PuppetDB. |
| `PUP-204` | The Puppet plugin **MUST** support batched facts retrieval for multiple nodes in a single query, using PQL. |
| `PUP-205` | The Puppet plugin **MUST** support fact-based search (e.g., "all nodes where `os.distro.codename = jammy`") via PQL, with results paginated. |
| `PUP-206` | The Puppet plugin **MUST** declare itself authoritative for the standard fact set: `os.*`, `kernel`, `processors.*`, `memory.*`, `networking.*`, `ipaddress*`, `fqdn`, `hostname`, `domain`. Custom facts are declared opportunistic. |
| `PUP-207` | The Puppet plugin **MUST** cache facts at a TTL configurable per integration, with default TTL in the minutes range. |

## 7.5 Configuration — Hiera

Hiera browsing is a flagship Puppet feature. The depth of inspection here distinguishes Vigil from generic infrastructure dashboards.

**Source of Hiera data.** All Hiera operations described in this section are performed against a **local copy of the Puppet control-repo**. Puppetserver's API does not expose Hiera data, lookup traces, or key-usage information, so the plugin reads the control-repo directly from disk. The control-repo path **MUST** be configurable per integration (see [section 7.14](#714-configuration-schema)). Vigil **MUST NOT** modify the control-repo — it reads only. The expected layout is the standard multi-environment checkout (one directory per environment, each containing its Hiera configuration file and data files).

### 7.5.1 Hierarchy browsing

| ID | Requirement |
|----|-------------|
| `PUP-301` | The Puppet plugin **MUST** allow browsing of the Hiera hierarchy as configured in the project's Hiera configuration file. The configuration filename **MUST** be configurable per integration; the default **MUST** be `hiera.yaml`. The plugin **MUST** read the file from the configured local control-repo path, scoped per environment. |
| `PUP-302` | The Puppet plugin **MUST** display the keys present at each level, with the values when the user drills in. |
| `PUP-303` | The Puppet plugin **MUST** support Hiera browsing scoped to a chosen environment. Environment isolation **MUST** be respected — a key from `production` Hiera **MUST NOT** appear when browsing `staging` Hiera unless the same key is independently defined in the `staging` hierarchy. |

### 7.5.2 Key resolution

| ID | Requirement |
|----|-------------|
| `PUP-311` | The Puppet plugin **MUST** support per-key resolution showing which hierarchy level provides the value for a given key in the context of a given node. |
| `PUP-312` | Per-key resolution **MUST** display the full lookup chain: which levels were consulted, which level returned a value, and what value was returned. |
| `PUP-313` | When resolution involves merge behavior (`hash`, `unique`, `deep`), the plugin **MUST** display the merge strategy and the contributing values from each level. |
| `PUP-314` | Resolution **MUST** respect node facts and parameters as inputs to hierarchy interpolation (e.g., `%{facts.os.distro.codename}` in level paths). |

### 7.5.3 Class-aware lookups

| ID | Requirement |
|----|-------------|
| `PUP-321` | The Puppet plugin **MUST** support class-aware Hiera lookups: given a node and the classes assigned to it, resolve the values that those classes' parameters would receive from Hiera (`automatic_parameter_lookup`). |
| `PUP-322` | The plugin **MUST** indicate, per parameter, whether the value comes from Hiera (and from which level), from a class default, or is unresolved (no Hiera entry, no default — would error at compile). |

### 7.5.4 Key usage analysis

| ID | Requirement |
|----|-------------|
| `PUP-331` | The Puppet plugin **MUST** support Hiera key usage analysis across the Puppet codebase: given a key, return the classes, profiles, and roles that consume it (via `lookup()` calls or automatic parameter lookup). |
| `PUP-332` | Usage analysis **MUST** include the file path and line where each consumption occurs. |
| `PUP-333` | Usage analysis **SHOULD** detect unused keys (defined in Hiera, never consumed in code) and surface them as a separate report. |
| `PUP-334` | Usage analysis **MUST** be implemented via static parsing of the local control-repo (the same local copy used for Hiera browsing — see [section 7.5](#75-configuration--hiera)). Puppetserver's API does not expose Hiera-related information, so all code analysis is performed against the local checkout. The control-repo path is configurable per integration (see [section 7.14](#714-configuration-schema)). |

## 7.6 Configuration — Catalogs

| ID | Requirement |
|----|-------------|
| `PUP-401` | The Puppet plugin **MUST** retrieve the latest compiled catalog for a given node from **PuppetDB** (where catalogs are already stored after each Puppet run). Retrieving catalogs from PuppetDB avoids the overhead of a dedicated catalog compilation on Puppetserver. On-demand catalog compilation from Puppetserver **MUST** remain available as an explicit user action (e.g., for catalog diff against a specific environment — see `PUP-404`) but **MUST NOT** be the default retrieval path. |
| `PUP-402` | Catalog views **MUST** display: resource declarations (type, title, parameters), classes assigned, defined types instantiated, and resource relationships (require, before, notify, subscribe). |
| `PUP-403` | Catalog views **MUST** support filtering by resource type, by class, and by resource title (substring match). |
| `PUP-404` | The Puppet plugin **MUST** support catalog diff in two modes: **(a)** between two environments on Puppetserver (involving on-demand catalog compilation for each environment); **(b)** between the latest catalog stored in PuppetDB and a freshly compiled catalog from Puppetserver for a selected environment. Mode (b) allows comparing the current production state against a proposed change without compiling both sides. The user **MUST** be able to choose which mode to use. |
| `PUP-405` | Catalog diff **MUST** highlight: resources only in one environment; resources in both with different parameters; resources in both with identical state. |
| `PUP-406` | Catalog compilation **MUST** respect environment isolation — the plugin **MUST NOT** mix code or data across environments. |

## 7.7 Configuration — Environments and code deployment

| ID | Requirement |
|----|-------------|
| `PUP-501` | The Puppet plugin **MUST** list available environments from Puppetserver. |
| `PUP-502` | The Puppet plugin **MUST** display each environment's metadata: name, code version (if available), last deploy timestamp, deploy initiator. |
| `PUP-503` | The Puppet plugin **MUST** support environment cache flushing on Puppetserver via the documented endpoints. |
| `PUP-504` | The Puppet plugin **MUST** support environment deployment via r10k or Code Manager: |
| `PUP-505` | — Where the deployment system exposes a webhook or API endpoint, the plugin **MUST** trigger deployment via that endpoint. |
| `PUP-506` | — Where webhook is unavailable, the plugin **MUST** support deployment via remote command execution against the Puppet master host (using a sibling execution integration). The plugin **MUST NOT** require its own SSH or shell capability for this. |
| `PUP-507` | Environment deployment progress and result **MUST** be reported back to the user, with the deployment outcome recorded as a system event. |
| `PUP-508` | Environment deployment **MUST** be RBAC-gated as a distinct action separate from generic configuration browsing. |

## 7.8 Events

| ID | Requirement |
|----|-------------|
| `PUP-601` | The Puppet plugin **MUST** retrieve resource-level events from PuppetDB (the `events` endpoint or PQL equivalent). |
| `PUP-602` | Each event **MUST** include: timestamp, node, resource type, resource title, status (success, failure, noop, skipped), old value, new value, message, file path, line number, and containment path (the chain of classes / defined types that include the resource). |
| `PUP-603` | Events **MUST** be grouped by their originating report (Puppet run). The user **MUST** be able to view all events from a single run together. |
| `PUP-604` | Events with status `noop` **MUST** be retrievable for diagnostic purposes but **MUST NOT** populate the journal by default. The platform's event-to-journal extraction (see [section 4](04-integration-types.md)) treats noop as steady-state. |
| `PUP-605` | The plugin **MUST** support time-range filtering of events server-side via PQL. |
| `PUP-606` | The plugin **MUST** support per-node filtering of events server-side via PQL. |
| `PUP-607` | The plugin **SHOULD** detect new events incrementally (using report hashes or report timestamps as checkpoints) rather than re-querying the full event log on each refresh. |

## 7.9 Reports

| ID | Requirement |
|----|-------------|
| `PUP-701` | The Puppet plugin **MUST** retrieve full Puppet run reports from PuppetDB. |
| `PUP-702` | Each report **MUST** include: |
| `PUP-703` | — Summary metrics: resource counts (total, changed, failed, skipped, noop), time breakdown by resource type, total run duration. |
| `PUP-704` | — Phase-level timing: facts gathering, catalog compilation, catalog application, report submission, and any other phases the report records. |
| `PUP-705` | — Corrective change detection: a clear flag on each event indicating whether the change was a correction of drift from desired state. |
| `PUP-706` | — Log entries: each with timestamp, level, source (resource or class), message, tags. |
| `PUP-707` | — Resource events with full drill-down (see section 7.8). |
| `PUP-708` | — Noop indicator: whether the run was executed in noop mode. |
| `PUP-709` | — Configuration version: the code version associated with the run. |
| `PUP-710` | — Environment: the environment the run was executed against. |
| `PUP-711` | The Puppet plugin **MUST** provide run history per node with trend visualization data (success/failure counts over time, average duration over time, change-event counts over time). |
| `PUP-712` | Reports **MUST** be navigable by: node, time range, status (succeeded, failed, with-changes, noop), environment. |
| `PUP-713` | Report retrieval **MUST** be paginated. |

## 7.10 Authentication and transport

| ID | Requirement |
|----|-------------|
| `PUP-801` | The Puppet plugin **MUST** support mTLS authentication to PuppetDB and Puppetserver using a client certificate, client key, and CA certificate provided in plugin configuration. |
| `PUP-802` | The plugin **MUST** support the standard Puppet token authentication where applicable (Puppet Enterprise RBAC token). |
| `PUP-803` | The plugin **MUST** verify the upstream server's certificate against the configured CA and **MUST NOT** disable verification by default. A "skip verification" mode **MAY** be exposed for development environments only, with a prominent warning. |
| `PUP-804` | Sensitive credentials (private keys, tokens) **MUST** be handled through the platform's secrets-aware mechanism. |
| `PUP-805` | The plugin **MUST** support PuppetDB API versions consistent with the supported Puppet versions (Puppet 7.x and 8.x at minimum) and **MUST** declare its supported version range. |

## 7.11 Resilience

| ID | Requirement |
|----|-------------|
| `PUP-901` | The Puppet plugin **MUST** implement circuit-breaker resilience against PuppetDB and Puppetserver per [section 11.6](11-platform-requirements.md#116-resilience). |
| `PUP-902` | The plugin **MUST** track health per sub-system (PuppetDB, Puppetserver, Hiera/local-control-repo) independently. PuppetDB unavailable **MUST NOT** disable Configuration capabilities served by Puppetserver or Hiera. Hiera (local control-repo) health is independent of both PuppetDB and Puppetserver availability. |
| `PUP-903` | The plugin **MUST** declare per-capability health: e.g., it can report Configuration as healthy while Reports is degraded if PuppetDB is slow but Puppetserver is fine. |
| `PUP-904` | When PuppetDB is unhealthy, the plugin **MUST** continue serving cached inventory, facts, events, and reports with explicit staleness markers. |

## 7.12 Caching

| ID | Requirement |
|----|-------------|
| `PUP-1001` | Cache TTL defaults **MUST** account for the fact that Puppet agent runs every 30 minutes by default, so data changes infrequently between runs. Inventory cache TTL default: 15 minutes. Facts cache TTL default: 30 minutes. Reports cache TTL default: 5 minutes (recent runs surface promptly) with longer TTL for completed historical reports (1 hour). Catalog cache TTL default: 30 minutes. Hiera cache TTL default: 15 minutes. All defaults **MUST** be overridable per integration. The on-demand cache flush mechanism (see `PUP-1005`) allows users to request fresh data without waiting for TTL expiry, which justifies these higher defaults. |
| `PUP-1002` | Cache **MUST** be invalidated when an environment deployment completes. Since Hiera data is read from local control-repo files, Hiera cache invalidation **MUST** be triggered when the local control-repo is updated (e.g., after a `git pull` or r10k/Code Manager sync). Catalog cache invalidation applies to catalogs stored in PuppetDB — the cache **MUST** be invalidated when PuppetDB reports new catalogs for the affected environment (detectable via report timestamps or webhook notification). |
| `PUP-1003` | The plugin **MUST** support configurable webhook receipt for cache invalidation, where the upstream Puppet deployment system can notify Vigil of code-deploy events. |
| `PUP-1004` | The plugin **MUST** deduplicate concurrent requests for the same data (request coalescing): if 50 users request the same node's facts within a cache miss window, the plugin **MUST** issue one upstream call. |
| `PUP-1005` | The plugin **MUST** expose an on-demand **cache flush** action, allowing users to request fresh data and force an update of local caches. Cache flush **MUST** be available per capability (e.g., flush only Hiera cache, or only catalog cache) and globally (flush all Puppet caches). This mechanism allows higher default TTLs while still giving operators immediate access to fresh data when needed. Cache flush **MUST** be RBAC-gated (see `PUP-1307`). |

## 7.13 Performance at scale

| ID | Requirement |
|----|-------------|
| `PUP-1101` | The Puppet plugin **MUST** handle inventories of 10,000 nodes in PuppetDB without functional degradation. |
| `PUP-1102` | All list endpoints **MUST** be served via PQL with server-side pagination — the plugin **MUST NOT** retrieve a 10,000-node fact set into memory. |
| `PUP-1103` | The plugin **MUST** prefer PuppetDB's bulk endpoints (`/pdb/query/v4`) over per-node iteration where bulk is available. |
| `PUP-1104` | The plugin **MUST** apply per-query result limits and reject queries that would return unbounded results, returning an actionable error. |
| `PUP-1105` | Catalog compilation requests **MUST** be subject to per-integration concurrency limits to avoid overwhelming Puppetserver. |

## 7.14 Configuration schema

The plugin's configuration schema **MUST** include at minimum the following fields:

| Field | Required | Description |
|-------|----------|-------------|
| `puppetdb.url` | yes (when PuppetDB enabled) | Base URL of PuppetDB |
| `puppetdb.client_cert` | yes (mTLS) | Path or reference to client certificate |
| `puppetdb.client_key` | yes (mTLS) | Path or reference to client private key |
| `puppetdb.ca_cert` | yes (mTLS) | Path or reference to CA certificate |
| `puppetdb.token` | conditional | API token (Puppet Enterprise alternative to mTLS) |
| `puppetdb.timeout` | no | Per-request timeout (default: 30s) |
| `puppetserver.url` | yes (when Puppetserver enabled) | Base URL of Puppetserver |
| `puppetserver.client_cert` | yes (mTLS) | Client certificate for Puppetserver |
| `puppetserver.client_key` | yes (mTLS) | Client key for Puppetserver |
| `puppetserver.ca_cert` | yes (mTLS) | CA cert for Puppetserver |
| `puppetserver.timeout` | no | Per-request timeout |
| `control_repo.path` | yes (when Hiera/code analysis enabled) | Local filesystem path to the Puppet control-repo checkout. Used for Hiera browsing and code analysis. The plugin reads only — it **MUST NOT** modify the control-repo. |
| `hiera.config_file` | no | Filename of the Hiera configuration file within each environment directory (default: `hiera.yaml`). Allows sites using non-standard naming to specify their configuration file. |
| `code_deploy.method` | no | `webhook`, `code_manager`, or `remote_exec` |
| `code_deploy.endpoint` | conditional | Webhook URL when method = `webhook` |
| `code_deploy.exec_integration` | conditional | Sibling execution integration ID when method = `remote_exec` |
| `cache_ttl.*` | no | Per-capability cache TTL overrides |
| `default_environment` | no | Environment shown by default in UI (default: `production`) |
| `show_deactivated` | no | Whether to include deactivated PuppetDB nodes by default |
| `circuit_breaker.*` | no | Circuit breaker tuning |

| ID | Requirement |
|----|-------------|
| `PUP-1201` | The Puppet plugin **MUST** validate the configuration above at `initialize` and **MUST** reject configurations that lack the credentials required for declared capabilities. |
| `PUP-1202` | The plugin **MUST** provide guided configuration with field-level validation feedback in the administration UI. |
| `PUP-1203` | The plugin **MUST** expose a "test connection" action that exercises a low-cost call against each configured sub-system and reports per-sub-system success/failure. |

## 7.15 RBAC integration

| ID | Requirement |
|----|-------------|
| `PUP-1301` | The Puppet plugin's actions **MUST** be governed by the platform RBAC. The following distinct permissions **MUST** exist: |
| `PUP-1302` | — `puppet:inventory:read` — view nodes |
| `PUP-1303` | — `puppet:facts:read` — view facts |
| `PUP-1304` | — `puppet:configuration:read` — view Hiera, catalogs, environment metadata |
| `PUP-1305` | — `puppet:events:read` — view resource events |
| `PUP-1306` | — `puppet:reports:read` — view reports and run history |
| `PUP-1307` | — `puppet:environment:flush_cache` — trigger environment cache flush |
| `PUP-1308` | — `puppet:environment:deploy` — trigger r10k / Code Manager deployment |
| `PUP-1309` | — `puppet:catalog:diff` — compare catalogs across environments |
| `PUP-1310` | The plugin **MUST NOT** bypass RBAC checks under any code path. RBAC is enforced before the underlying Puppetserver / PuppetDB call is issued. |

## 7.16 Journal contributions

| ID | Requirement |
|----|-------------|
| `PUP-1401` | The Puppet plugin **MUST** contribute journal entries for: each resource change event extracted from a Puppet run report; each environment deployment action triggered through Vigil; each environment cache flush triggered through Vigil. |
| `PUP-1402` | Resource change events **MUST** be grouped under their originating report in the journal UI. |
| `PUP-1403` | Noop runs **MUST NOT** generate journal entries. |
| `PUP-1404` | Failed reports (compilation errors, agent failures) **MUST** generate a journal entry summarizing the failure with a link to the full report. |

## 7.17 Acceptance criteria

The Puppet integration is considered complete when, in order:

1. PuppetDB nodes appear in unified inventory with status, facts, and source attribution.
2. Facts are retrievable per node and searchable by fact value via PQL.
3. Hiera browsing works with hierarchy levels visible and per-key resolution showing which level provided each value.
4. Class-aware Hiera lookups return parameter values for a node's assigned classes.
5. Hiera key usage analysis returns consuming classes with file/line references.
6. Compiled catalogs are retrievable per node per environment.
7. Catalog diff between two environments works correctly.
8. Environment list, cache flush, and code deployment all work, with deployment supporting at least webhook and remote-execution methods.
9. Resource events from reports are extracted, grouped per report, and feed the journal (with no-op events excluded).
10. Full Puppet run reports are retrievable with all required metrics, logs, phase timings, and drill-down.
11. Run history per node displays trend data.
12. mTLS authentication works against PuppetDB and Puppetserver.
13. Circuit breaker correctly trips on consecutive failures and recovers on probe success.
14. Cached data is served with staleness markers when PuppetDB is unhealthy.
15. All operations remain functional and responsive at 10,000 nodes.

---

[← Previous: Plugin Architecture](06-plugin-architecture.md) | [Next: Bolt, Ansible, SSH →](08-priority-1-integrations.md)

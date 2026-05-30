# 6. Plugin Architecture

The plugin architecture is the foundation of Vigil. Every integration — built-in or community-contributed — implements the same contract. The platform has no special path for first-party plugins. This section defines the contract, the lifecycle, the distribution model, and the isolation guarantees.

## 6.1 Goals

- **Uniformity.** A community plugin loaded at runtime is indistinguishable, at the runtime level, from a plugin shipped with the application.
- **Replaceability.** Disabling a plugin removes its UI surface entirely. Enabling a different plugin that provides the same types brings the surface back. No code changes required.
- **Isolation.** A misbehaving plugin must not crash the application or starve other plugins of resources.
- **Composability.** A node may be known to multiple plugins simultaneously. The platform reconciles overlap; plugins do not.

## 6.2 Plugin contract

| ID | Requirement |
|----|-------------|
| `PLUG-001` | Every plugin **MUST** declare a unique plugin identifier (stable across versions). |
| `PLUG-002` | Every plugin **MUST** declare its supported integration types from the canonical set defined in [section 4](04-integration-types.md). |
| `PLUG-003` | Every plugin **MUST** declare its configuration schema, including required fields, optional fields, default values, and per-field validation rules. |
| `PLUG-004` | Every plugin **MUST** declare its required permissions on the host system (file paths it reads, executables it invokes, network endpoints it contacts, credentials it uses). The platform **MUST** display this declaration to administrators on enable. |
| `PLUG-005` | Every plugin **MUST** declare per-capability default cache TTLs and timeout values. The platform **MUST** allow administrators to override these per integration. |
| `PLUG-006` | Every plugin **MUST** implement the lifecycle hooks defined in [section 6.3](#63-lifecycle-hooks). |
| `PLUG-007` | Every plugin **MUST** implement the data contracts of every integration type it declares, as defined in [section 4](04-integration-types.md). |
| `PLUG-008` | Every plugin **MUST** report errors through a standardized error contract that distinguishes: configuration errors, transient external errors, persistent external errors, internal plugin errors, and authorization errors from the upstream system. |
| `PLUG-009` | A plugin **MUST NOT** assume any other plugin is loaded. Cross-plugin coordination, where required, **MUST** flow through the platform. |
| `PLUG-010` | A plugin **MUST NOT** read or modify global platform state outside its declared resources. |
| `PLUG-011` | A plugin **MUST** make all outbound calls (network, subprocess) idempotent for read operations and side-effect-free for capability discovery (`introspect`, `list templates`, etc.). |
| `PLUG-012` | A plugin **MUST** return data with consistent identity attributes across calls so the platform can deduplicate and link nodes correctly. |
| `PLUG-013` | Every plugin **MUST** expose an on-demand **cache flush** action that allows users to request fresh data and force an update of local caches. Cache flush **MUST** be available per capability (e.g., flush only facts, or only inventory) and globally (flush all caches for the plugin). This mechanism enables higher default cache TTLs while still giving operators immediate access to fresh data when needed. Cache flush actions **MUST** be RBAC-gated. |

## 6.3 Lifecycle hooks

Every plugin **MUST** implement the following hooks. The platform invokes them in the order described.

### 6.3.1 Initialize

| ID | Requirement |
|----|-------------|
| `PLUG-101` | The platform **MUST** invoke `initialize` once per integration instance at startup or after configuration change. |
| `PLUG-102` | `initialize` **MUST** validate configuration, establish any persistent connections or session tokens, and report success or a structured failure. |
| `PLUG-103` | If `initialize` fails, the integration **MUST** be marked unhealthy. It **MUST NOT** receive data-fetch or action calls until `initialize` succeeds on a subsequent retry. |
| `PLUG-104` | `initialize` **MUST NOT** block longer than the per-plugin initialization timeout. The platform **MUST** treat overrun as an initialization failure. |

### 6.3.2 Health check

| ID | Requirement |
|----|-------------|
| `PLUG-111` | The platform **MUST** invoke `health_check` periodically per integration at the configured interval (default: 30s, configurable per integration). |
| `PLUG-112` | `health_check` **MUST** return a per-capability status (healthy, degraded, unhealthy) with a diagnostic message and a last-success timestamp where applicable. |
| `PLUG-113` | `health_check` **MUST NOT** perform expensive operations. It **SHOULD** use lightweight liveness probes (a token-validate call, an inventory-count call) rather than full data fetches. |
| `PLUG-114` | The platform **MUST** track health check history per integration to detect flapping and trigger circuit-breaker behavior. |

### 6.3.3 Data and action calls

| ID | Requirement |
|----|-------------|
| `PLUG-121` | Each declared integration type **MUST** be served by a corresponding capability call (e.g., `list_inventory`, `get_facts`, `execute_command`). |
| `PLUG-122` | All capability calls **MUST** accept a deadline / timeout parameter from the platform and **MUST** abort cleanly when the deadline passes. |
| `PLUG-123` | All capability calls **MUST** be safe to invoke concurrently against the same integration unless the underlying tool requires serialization, in which case the plugin **MUST** serialize internally rather than failing. |
| `PLUG-124` | Long-running capability calls (executions, provisioning) **MUST** stream progress through the platform's streaming contract rather than holding a synchronous response. |

### 6.3.4 Shutdown

| ID | Requirement |
|----|-------------|
| `PLUG-131` | The platform **MUST** invoke `shutdown` per integration at application stop or on integration disable. |
| `PLUG-132` | `shutdown` **MUST** terminate in-flight requests, close persistent connections, and release resources within a fixed timeout. |
| `PLUG-133` | `shutdown` **MUST NOT** block indefinitely. If a plugin's `shutdown` overruns its timeout, the platform **MUST** consider the plugin terminated and continue. |

## 6.4 Configuration

| ID | Requirement |
|----|-------------|
| `PLUG-201` | The platform **MUST** load plugin configuration from a single, authoritative configuration source. |
| `PLUG-202` | The platform **MUST** validate plugin configuration against the plugin's declared schema before invoking `initialize`. |
| `PLUG-203` | Configuration validation errors **MUST** be reported with the field path, the violated rule, and an actionable remediation hint. |
| `PLUG-204` | Sensitive configuration values (credentials, certificates, tokens) **MUST** be handled through a secrets-aware mechanism that does not expose them in logs, error messages, or UI displays. |
| `PLUG-205` | The platform **MUST** support reload of plugin configuration without full application restart. Reload **MUST** preserve in-flight operations or terminate them with a clean error. |
| `PLUG-206` | The platform **MUST** allow administrators to enable and disable plugins per integration without code changes, restart, or redeployment. |

## 6.5 Distribution model

| ID | Requirement |
|----|-------------|
| `PLUG-301` | The platform **MUST** support two distribution models, treating them identically at runtime: |
| `PLUG-302` | **First-party plugins** (Puppet, Bolt, Ansible, SSH, Proxmox, AWS, Azure) **MUST** ship with the application distribution. |
| `PLUG-303` | **Community plugins** **MUST** be installable as runtime-loaded packages without modifying or rebuilding the application. |
| `PLUG-304` | Plugin discovery **MUST** happen at application startup. The platform **MUST** enumerate all available plugins (shipped + installed) and present them to administrators for configuration. |
| `PLUG-305` | A plugin **MUST** declare its compatibility range against the platform contract version. The platform **MUST** refuse to load a plugin that declares incompatibility. |
| `PLUG-306` | The platform **MUST** provide a published, versioned plugin contract specification that community authors can target without privileged access to the platform's source. |
| `PLUG-307` | The platform **MUST NOT** treat first-party plugins as more privileged than community plugins for purposes of configuration, RBAC, or runtime resource allocation. |

## 6.6 Isolation

| ID | Requirement |
|----|-------------|
| `PLUG-401` | A failing plugin **MUST NOT** crash the platform. The platform **MUST** isolate plugin failures to the affected integration. |
| `PLUG-402` | The platform **MUST** apply per-plugin resource budgets (memory, connection pool size, concurrent calls) configurable per integration. |
| `PLUG-403` | The platform **MUST** enforce per-capability call timeouts and **MUST** terminate a plugin call that overruns its deadline. |
| `PLUG-404` | A plugin **MUST NOT** be able to consume more than its declared budget. The platform **MUST** queue or reject excess concurrent calls and **MUST** report the rejection through the standard error contract. |
| `PLUG-405` | Plugins **MUST** run within the application runtime (in-process) for performance reasons. Process-level isolation is not required for the initial release but **MUST NOT** be precluded by the contract design. |
| `PLUG-406` | The platform **MUST** isolate plugin logging, metrics, and diagnostic output so that one plugin's noise does not obscure another plugin's signal. |
| `PLUG-407` | The platform's plugin isolation is **fault isolation and resource isolation, not data isolation**. In-process plugins run in the same runtime memory space and, absent additional controls, can introspect other plugins' internal state. The platform **MUST** document a trust boundary: installed plugins are assumed trustworthy at the same level as platform code. Installing an untrusted or unvetted plugin is a security decision equivalent to installing untrusted code on the host. |
| `PLUG-408` | Until a process-level plugin isolation model is introduced (out of scope for the initial release), the platform **MUST NOT** represent itself as capable of safely hosting adversarial or untrusted plugins. Community plugins are supported, but the operator is responsible for vetting them before enabling them in production. |
| `PLUG-409` | Plugins **MUST NOT** access platform-internal storage, caches, message topics, or module APIs outside the published plugin contract. This is a contract obligation on plugin authors (`PLUG-009`, `PLUG-010`) and is verified by the conformance suite where practical; it is not a hard runtime boundary at this release. The platform **SHOULD** enforce what it can (named ETS tables with restricted access modes, scoped PubSub topic prefixes, hidden registries) but **MUST NOT** rely on enforcement as the primary defence — contract adherence is. |

## 6.7 Supplementary capabilities and UI extension slots

Beyond the nine generic integration types, a plugin may declare **supplementary capabilities** — integration-specific features that do not fit the shared abstraction. These are the mechanism by which a plugin exposes rich, tool-native UI and logic without the platform needing prior knowledge of what each integration does.

Examples: Puppet's catalog diff, Hiera key lookup, code analysis; Ansible's variable browser; AWS's resource topology view.

### 6.7.1 Extension slot types

The platform defines three extension slots that supplementary capabilities may occupy:

| Slot | Rendered where | Description |
|------|---------------|-------------|
| `node_tab` | Extra tab on the node detail page, appended after generic tabs | Plugin-specific per-node view. Only shown when the plugin reports this node and the user has the required permission. |
| `global_page` | Sidebar entry under the integration's navigation section | Plugin-specific page with its own URL, accessible from the main navigation. May display cross-node data, plugin-specific node lists with custom columns, or tool-native workflows. |
| `node_action` | Button or menu item in the node action bar on the node detail page | Plugin-specific action, typically triggering a plugin capability call with output rendered in a dedicated view or panel. |

### 6.7.2 Supplementary capability declaration

| ID | Requirement |
|----|-------------|
| `PLUG-801` | A plugin **MAY** declare zero or more supplementary capabilities in its manifest in addition to its generic integration types. |
| `PLUG-802` | Each supplementary capability declaration **MUST** include: a stable capability identifier (e.g., `puppet:catalog_diff`), a display name, a description, an extension slot type (`node_tab`, `global_page`, or `node_action`), and an RBAC permission identifier. |
| `PLUG-803` | Each supplementary capability **MUST** declare its data contract: the structure of data the plugin provides for this capability, and any parameters the capability accepts. |
| `PLUG-804` | Each supplementary capability **MUST** declare a UI component (a platform-native UI module) that renders its data in the assigned slot. First-party and community plugins alike may ship full UI components — this is consistent with the plugin trust model (`PLUG-407`, `PLUG-408`). |
| `PLUG-805` | The platform **MUST** mount declared supplementary capability components in their assigned slots at runtime. `node_tab` and `node_action` components are mounted only when the plugin is linked to the node being viewed. `global_page` components are accessible whenever the integration is enabled. |
| `PLUG-806` | Supplementary capability components **MUST NOT** be mounted when the requesting user lacks the required permission for that capability. The platform **MUST** hide the slot entirely — it **MUST NOT** render a disabled or greyed-out placeholder. |
| `PLUG-807` | The platform **MUST** provide a published UI component library — the same primitives used by first-party plugins — that community plugin authors can use to achieve visual consistency with the rest of the product. Use of the component library is strongly recommended but not enforced. |
| `PLUG-808` | A plugin's supplementary capability identifier **MUST** be namespaced by the plugin identifier (e.g., `puppet:catalog_diff`, not `catalog_diff`) to prevent collision across plugins. |
| `PLUG-809` | Supplementary capability data calls **MUST** follow the same timeout, caching, and error-contract rules as generic capability calls. A failing supplementary capability **MUST NOT** affect the rendering of generic tabs or other plugins' supplementary capabilities on the same page. |
| `PLUG-810` | Supplementary capabilities **MUST** be independently RBAC-gated. A user with `puppet:configuration:read` does not automatically gain `puppet:catalog_diff` — the catalog diff is a separate permission that must be explicitly granted. |
| `PLUG-811` | The conformance test suite (`PLUG-701`) **MUST** include a supplementary capability test fixture, verifying that declared slots, data contracts, and RBAC identifiers are well-formed. |

### 6.7.3 Navigation and discoverability

| ID | Requirement |
|----|-------------|
| `PLUG-901` | The platform **MUST** render a sidebar section per enabled integration, listing its declared `global_page` supplementary capabilities as navigation entries. |
| `PLUG-902` | If an integration declares no `global_page` capabilities, its sidebar section **MUST NOT** appear — integrations that provide only generic types have no integration-specific navigation entries. |
| `PLUG-903` | The integration administration UI **MUST** list all supplementary capabilities declared by each plugin, including their slot type and RBAC permission identifier, so administrators can assign permissions accurately. |
| `PLUG-904` | The platform **MUST** handle the case where a plugin is disabled or unhealthy: `node_tab` and `node_action` slots for that plugin **MUST** be hidden; `global_page` entries **MUST** remain in the navigation but display a clear unavailable state rather than a broken page. |

## 6.8 Plugin identity in the data model

| ID | Requirement |
|----|-------------|
| `PLUG-501` | Every record produced by a plugin (node, fact, event, journal entry, report, configuration item) **MUST** carry source attribution: at minimum the plugin identifier and the integration instance identifier. |
| `PLUG-502` | The platform **MUST** preserve source attribution through aggregation, deduplication, and caching. A user viewing aggregated data **MUST** be able to ask "where did this come from?" and receive a precise answer. |
| `PLUG-503` | The facts view **MUST** display all facts from all sources in a unified list. Each fact entry **MUST** carry a visible source badge naming the contributing integration(s). When multiple sources report the same key with the same value, the platform **MUST** show one row with all contributing source badges. When sources disagree on a value, the platform **MUST** show a separate row per differing value, each with its source badge — conflicts are visible without any drill-in. The view **MUST** provide a per-source filter that narrows the displayed rows to facts from a selected integration only. |
| `PLUG-504` | Plugin identity **MUST** be stable across upgrades unless explicitly changed by the plugin author, in which case the platform **MUST** offer a migration path that preserves linked-node assignments. |

## 6.8 Versioning

| ID | Requirement |
|----|-------------|
| `PLUG-601` | The plugin contract **MUST** be versioned independently of the platform application. |
| `PLUG-602` | Breaking changes to the plugin contract **MUST** increment the major version. The platform **MUST** support at least the current and previous major contract versions concurrently for a defined deprecation window. |
| `PLUG-603` | The platform **MUST** display, in the integration administration UI, the contract version each loaded plugin targets. |

## 6.9 Plugin testing

The plugin contract is the load-bearing abstraction of the system. It is heavily tested.

| ID | Requirement |
|----|-------------|
| `PLUG-701` | The platform **MUST** ship a contract-conformance test suite that any plugin can run against itself to validate its implementation. |
| `PLUG-702` | The platform **MUST** ship a reference "no-op" plugin that exercises all lifecycle hooks and capability calls, demonstrating the contract end-to-end. The reference plugin doubles as a smoke test for platform changes. |
| `PLUG-703` | First-party plugins **MUST** pass the conformance suite as a prerequisite for release. |
| `PLUG-704` | The platform **MUST** run the conformance suite against every loaded plugin at startup in a "validation" mode (light-touch, non-side-effecting) and **MUST** flag deviations to administrators. |

---

[← Previous: Integration Matrix](05-integration-matrix.md) | [Next: Puppet Integration →](07-puppet-integration.md)

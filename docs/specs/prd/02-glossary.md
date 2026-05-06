# 2. Glossary

Terms in this glossary are used throughout the document with the precise meaning defined here. Where a term appears in code, configuration, or UI text, its definition here is normative.

## A

**Action**
A discrete operation a user can perform — viewing inventory, executing a command, provisioning a VM, adding a journal note. Actions are the unit of permission enforcement under RBAC.

**Administrator**
A user with permissions to configure integrations, manage users and roles, change linking rules, and modify system settings.

**Aggregation**
The process of combining responses from multiple integrations into a single result (e.g., unified inventory, global journal). Aggregation is per-request and respects per-source health.

**Audit trail**
A record of user-initiated actions — who, what, when, against which target, with what outcome. Distinct from the journal: the journal is per-node history; the audit trail is per-user activity.

## C

**Capability**
One of the nine integration types that an integration plugin declares it provides. A plugin may provide several capabilities (e.g., Puppet provides Inventory, Facts, Configuration, Events, Reports).

**Catalog (Puppet)**
The compiled set of resources Puppetserver computes for a node in a given environment. Vigil reads catalogs; it does not produce them.

**Circuit breaker**
A resilience pattern: after `N` consecutive failures to an upstream service, the system stops calling that service for a cooldown period, then probes for recovery before resuming.

**Configuration item**
A desired-state declaration scoped to a node — a Hiera key, a catalog resource, an Ansible variable, a class parameter. See also: *Fact*.

## D

**Deduplication**
The process of recognizing that two records from different sources describe the same node, and presenting them as one. See *Linking*.

**Degraded state**
An integration's health when some capabilities work and others do not (e.g., PuppetDB inventory queries succeed but report queries time out).

**Deployment (capability)**
Read-only visibility into application releases on a node — what version of what application was deployed when. Vigil does not perform deployments.

## E

**Environment (Puppet)**
A named slice of Puppet code and Hiera data (e.g., `production`, `staging`). Catalogs are computed per environment. Hiera lookups respect environment isolation.

**Event**
A discrete state transition recorded against a node — a resource changed, a check went from OK to CRITICAL, an instance was rebooted, a deployment landed. Events feed the journal.

**Execution**
A single invocation of a remote command, task, or playbook against one or more nodes. Has streaming output, an exit status, a duration, a recorded full transcript, and per-target metadata.

**External authentication**
Authentication delegated to an identity provider (SAML, OIDC, LDAP). External users authenticate via their IdP only — they have no local password.

## F

**Fact**
An observed, point-in-time attribute of a node — OS version, CPU count, network interface, installed package, uptime. Facts are descriptive ("what IS"), not prescriptive ("what SHOULD be"). See also: *Configuration item*.

**FQDN**
Fully qualified domain name. One of the candidate identity attributes used for cross-source node linking.

## G

**Group**
A named collection of nodes. Groups may originate from one or more integrations (an Ansible group, a Puppet inventory group, a Proxmox cluster node, a cloud tag). Groups with matching names across sources are linked.

**Group-to-role mapping**
The configuration that maps external IdP group memberships onto Vigil roles. Multiple memberships are additive.

## H

**Health check**
A periodic probe of an integration's reachability and per-capability functionality. Results drive the integration status dashboard and degraded-state markers.

**Hiera**
Puppet's hierarchical configuration data system. Vigil reads Hiera data, resolves values in node context, and shows which hierarchy level provided each value. Vigil does not edit Hiera files.

## I

**Identity**
The set of attributes (hostname, certname, FQDN, IP) by which a node is known. A canonical identity is resolved per node by the linking rules.

**Integration**
A configured connection to an external tool. An integration is an instance of a plugin with concrete configuration (URL, credentials, options). The same plugin may be configured as multiple integrations (e.g., two AWS accounts).

**Integration type**
One of the nine fundamental interaction patterns: Inventory, Facts, Configuration, Events, Monitoring, Reports, Remote Execution, Provisioning, Deployment. See [04-integration-types.md](04-integration-types.md).

**Inventory**
The set of known nodes. Per-source: nodes from one integration. Unified: nodes from all integrations, deduplicated and linked.

## J

**Journal**
A per-node, time-ordered timeline of significant events. Sourced from events, reports, executions, provisioning actions, deployments, monitoring state changes, and manual notes. The journal is what an operator reads to answer "what changed?".

**Journal entry**
A single record in the journal. Has a type, source integration, timestamp, summary, and optional structured details. Entries link back to their source artifact (report, execution, etc.) where applicable.

**JIT provisioning**
Just-in-time creation of a Vigil user record on first successful authentication via an external IdP. No pre-provisioning is required.

## L

**Linking**
The process by which records from different integrations are recognized as the same node (or the same group). May be automatic (rule-based) or manual (admin-overridden).

**Linking rule**
A configurable heuristic for automatic linking — e.g., "match by certname," "fall back to FQDN," "case-insensitive hostname." Rules apply globally unless overridden.

**Live-updating**
A UI pattern in which displayed data changes without a page reload, driven by push (server-sent updates) or short-polling.

## M

**Manual link / unlink**
An administrator's explicit decision to link or unlink two records, overriding automatic heuristics. Persists across rule changes.

**MCP server**
A Model Context Protocol server exposed by Vigil, providing read-only infrastructure tools to external AI agents. Same RBAC as the web UI.

**Monitoring (capability)**
The capability that reports current health: check status, service state, metric values, active alerts. State *changes* observed by monitoring also feed the journal.

## N

**Node**
A managed server, virtual machine, or container. The atomic unit of Vigil's domain model. May be known by one or many integrations. Has zero or more facts, configuration items, journal entries, and reports.

**No-op (Puppet)**
A run that detected no required changes, or a resource event indicating "would have changed but did not." No-op events are not surfaced to the journal.

## P

**PQL**
Puppet Query Language. The query syntax for PuppetDB. Vigil uses PQL for server-side filtering wherever practical.

**Plugin**
A unit of code that implements one or more integration types against a specific external tool. Plugins are loaded at startup and conform to a uniform contract regardless of distribution origin.

**Plugin contract**
The set of declarations and lifecycle hooks every plugin must implement. See [06-plugin-architecture.md](06-plugin-architecture.md).

**Provisioning (capability)**
Create / destroy / lifecycle operations on virtual machines and containers, plus discovery of resources available for provisioning (templates, sizes, networks).

## R

**RBAC**
Role-based access control. Permissions are assigned to roles; roles are assigned to users (directly for local users, via group mapping for external users).

**Report**
A structured result of a completed run or scan — Puppet run report, vulnerability scan, etc. Contains summary metrics and resource-level detail. May produce events.

**Re-execution**
The act of repeating a previous execution against the same or revised target set, with one click.

**Resource (Puppet)**
A unit of desired state managed by Puppet (a file, package, service, user). Resources appear in catalogs and report events.

**Role**
A named set of permissions. Bound to users (locally assigned) or to external IdP groups (via mapping). Permissions cover integration types, specific integrations, and specific actions.

## S

**Source**
The integration from which a piece of data originated. All aggregated data carries source attribution.

**Stale data**
Cached data whose underlying source has not been refreshed within the configured TTL, typically because the source is unhealthy. Always served with a marker.

**Streaming output**
Real-time delivery of an execution's stdout/stderr to the UI as it is produced on the target node.

## T

**Target**
A node, group, or ad-hoc list of nodes selected as the destination for an execution or provisioning action.

**TTL**
Time-to-live for a cache entry. Configurable per integration and per data type.

## U

**Unified inventory**
The aggregated, deduplicated, source-attributed list of all nodes known by all healthy integrations.

**User**
An authenticated person or service account. Has one or more roles. Local users have a Vigil-managed password; external users authenticate via an IdP only.

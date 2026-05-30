# Vigil — Domain Glossary

Terms are listed alphabetically. Definitions here are normative: where they conflict with earlier drafts, this file wins.

---

## A

**Action**
A discrete operation a user can perform. The atomic unit of RBAC permission enforcement.

**Approval gate** *(EE only)*
A configuration-driven policy that intercepts high-impact actions (execution, provisioning, code deployment) before they run. Rules match on action type, target scope, and submitter role. Matched actions are queued pending approval from a designated approver role; the submitter cannot approve their own action. CE's extension point passes through all actions without queuing.

**Aggregation**
Combining responses from multiple integrations into a single result. Done per-request; respects per-source health.

**Audit trail**
Persisted record of user-initiated actions: who, what, when, against which target, with what outcome. Distinct from the Journal: the journal is per-node history; the audit trail is per-user activity.

---

## B

**Break-glass account**
The canonical local administrator account that always exists in CE deployments and cannot be deleted or bound to an external IdP. Used when external authentication (OIDC, SAML, LDAP) is unavailable. All break-glass logins are marked distinctly in the audit trail and trigger an alert. In EE deployments with local auth disabled, this account is also disabled — the operator is responsible for an out-of-band access path.

## C

**Capability**
One of the nine integration types that a plugin declares it provides. A plugin may provide several capabilities.

**Circuit breaker**
A resilience pattern: after N consecutive failures to an upstream service, the system stops calling that service for a cooldown period, then probes for recovery before resuming. Applied per integration, per capability.

**Community plugin**
A plugin authored outside the Vigil project and distributed by third parties. Installed by placing a valid OTP application directory in the configured plugin directory before Vigil starts; discovered and loaded at boot time. Requires a Vigil restart to enable or disable — there is no hot-load path. Treated identically to first-party plugins at runtime.

**Configuration item**
A desired-state declaration scoped to a node — a Hiera key, a catalog resource, an Ansible variable, a class parameter. Descriptive of intent ("what SHOULD be"). Contrast with *Fact*.

---

## D

**Deduplication**
Recognising that two records from different sources describe the same node and presenting them as one. See *Linking*.

**Degraded state**
An integration's health when some capabilities work and others do not.

**Deployment** *(capability)*
Read-only visibility into application releases on a node. Vigil does not perform deployments.

---

## E

**Event**
A discrete state transition recorded against a node. Events feed the Journal.

**Execution**
A single invocation of a remote command, task, or playbook against one or more nodes. Has streaming output, an exit status, a duration, a recorded full transcript, and per-target metadata.

---

## F

**Fact**
An observed, point-in-time attribute of a node (OS version, CPU count, network interface). Descriptive ("what IS"). Contrast with *Configuration item*.

**First-party plugin**
A plugin shipped with the Vigil application distribution (Puppet, Bolt, Ansible, SSH, Proxmox, AWS, Azure). Treated identically to community plugins at runtime.

---

## G

**Group**
A named collection of nodes. May originate from one or more integrations.

**Group-to-role mapping**
The configuration that maps external IdP group memberships onto Vigil roles. Resolution is always additive: a user in N matched groups receives the union of all corresponding roles (satisfying DM-301 in all editions). CE supports literal (exact string) group name matching, evaluated at JIT provisioning time. EE adds wildcard patterns (e.g., `ops-*`) and re-evaluation on every login so IdP group changes take effect immediately without re-provisioning.

---

## H

**Health check**
A periodic, lightweight probe of an integration's reachability and per-capability functionality. Drives integration status and degraded-state markers.

---

## I

**Integration**
A configured connection to an external tool. An instance of a plugin with concrete configuration (URL, credentials, options). Multiple integrations may share the same plugin (e.g., two AWS accounts).

**Integration type**
One of the nine fundamental interaction patterns: Inventory, Facts, Configuration, Events, Monitoring, Reports, Remote Execution, Provisioning, Deployment.

**Inventory**
The set of known nodes. Per-source: nodes from one integration. Unified: nodes from all integrations, deduplicated and linked.

---

## J

**Journal**
A per-node, time-ordered timeline of significant events, sourced from multiple integrations plus manual notes. The primary answer to "what changed on this node?"

**Journal entry**
A single record in the Journal. Has a type, source integration, timestamp, summary, and optional structured details.

---

## L

**Linking**
The process by which records from different integrations are recognised as the same node (or group). May be automatic (rule-based) or manual (admin-overridden).

**Linking rule**
A configurable heuristic for automatic linking. The default cascade is: certname → FQDN → hostname → primary IP. IP matching is on by default; it is a valid stable identifier in production environments where VMs are long-lived. Operators may disable IP matching globally or per integration if their environment has volatile IPs (e.g., heavy cloud auto-scaling with recycled addresses). IP claims are released when a node is decommissioned, preventing false re-linking to a new node at the same address.

---

## M

**MCP server**
A Model Context Protocol server exposed by Vigil. Provides read-only infrastructure tools to external AI agents. Enforces the same RBAC as the web UI.

---

## N

**Node**
A managed server, virtual machine, or container. The atomic unit of Vigil's domain model. Has a persisted identity record (canonical ID, linking metadata) and derived data (facts, config, monitoring state) fetched live from source integrations. A node's identity record is never automatically deleted; it transitions through states: **Active** (reported by at least one integration), **Unreported** (no integration currently reports it), **Decommissioned** (explicitly tombstoned by an administrator).

**Node decommission**
An explicit administrator action that tombstones a node identity record. Removes it from the active inventory view, releases all identity claims (including IP) for re-linking, and retains it as a historical reference for Journal entries and Executions.

---

## P

**Plugin**
A unit of code that implements one or more integration types against a specific external tool. Packaged as an OTP application. Conforms to the plugin contract regardless of whether it is first-party or community-authored.

**Plugin contract**
The versioned set of declarations and lifecycle hooks every plugin must implement.

**Supplementary capability**
A plugin-declared feature beyond the nine generic integration types. Occupies one of three platform extension slots: `node_tab` (extra tab on the node detail page), `global_page` (sidebar entry under the integration, including plugin-specific node list views), or `node_action` (button in the node action bar). Independently RBAC-gated. Hidden entirely when the user lacks permission — never greyed out. Both first-party and community plugins may declare supplementary capabilities with full UI components, consistent with the plugin trust model.

**Extension slot**
One of three locations in the platform UI where a plugin's supplementary capability can be mounted: `node_tab`, `global_page`, or `node_action`. The platform renders the slot at runtime from the plugin's declared UI component. Slots are hidden when the plugin is not linked to the viewed node (`node_tab`, `node_action`) or when the integration is disabled (`global_page` shows an unavailable state).

**Provisioning** *(capability)*
Create/destroy/lifecycle operations on virtual machines and containers.

---

## R

**RBAC**
Role-based access control. Permissions are assigned to roles; roles are assigned to users (directly for local users, via group mapping for external users). Target scope restrictions apply to all surfaces — a user restricted to the `web-servers` group cannot see other nodes in inventory, facts, or configuration views, not only in execution. Filtering is applied at presentation time against a shared integration cache; the cache itself is not scoped per-principal.

**Report**
A structured result of a completed run or scan (e.g., Puppet run report, vulnerability scan). May produce Journal entries.

---

## S

**Source**
The integration from which a piece of data originated. All aggregated data carries source attribution.

**Stale data**
Cached data whose underlying source has not been refreshed within the configured TTL. Always served with a staleness marker; never silently removed.

---

## T

**Target**
A node, group, or ad-hoc list of nodes selected as the destination for an execution or provisioning action.

---

## U

**Unified inventory**
The aggregated, deduplicated, source-attributed list of all nodes known by all healthy integrations.

**User**
An authenticated person or service account. Local users have a Vigil-managed password; external users authenticate via an IdP only and have no local password.

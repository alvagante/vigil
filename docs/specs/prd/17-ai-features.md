# 17. AI-Assisted Features

The system provides two distinct AI-related surfaces: an **MCP server** for external AI agents to query infrastructure state, and **embedded AI-assisted inference** for in-product analysis. Both are Priority 2 features.

These features are **complementary, not overlapping**:

- The MCP server makes Vigil's infrastructure data available to external AI tooling (IDE assistants, chat interfaces, automation pipelines).
- The embedded AI-assisted inference uses an LLM (configured by the user) to produce structured insights *inside* Vigil's UI from data the user is already looking at.

Neither is a general-purpose chat interface. Both are constrained by the same RBAC model that governs the rest of the system.

## 17.1 MCP Server

The MCP (Model Context Protocol) server exposes well-shaped, read-only infrastructure tools to external AI agents.

### 17.1.1 Scope

| ID | Requirement |
|----|-------------|
| `MCP-001` | The MCP server **MUST** expose **read-only** infrastructure tools: inventory queries, node fact retrieval, status checks, group membership, journal queries, report retrieval. |
| `MCP-002` | The MCP server **MUST NOT** expose remote-execution or provisioning tools without explicit, separate opt-in by the administrator. Default state: read-only. |
| `MCP-003` | If an administrator enables write-side MCP tools in the future, the platform **MUST** require per-tool RBAC consent and **MUST** make the action attributable to a specific authenticated principal. |
| `MCP-004` | The MCP server **MUST NOT** expose configuration management actions (modifying integrations, users, roles) under any circumstance. |

### 17.1.2 Tool design

| ID | Requirement |
|----|-------------|
| `MCP-101` | MCP tools **MUST** be optimized for AI consumption: structured responses, reasonable token sizes, pre-summarized where appropriate. |
| `MCP-102` | Tools **MUST** return data with consistent schemas suitable for type-checking by AI tooling. |
| `MCP-103` | Tools **MUST** support pagination so an AI can request more detail when needed without overflowing its context. |
| `MCP-104` | Tools **MUST** support filtering at the input level — an AI agent **MUST NOT** need to retrieve a 10,000-node inventory to find one node by name. |
| `MCP-105` | Tool descriptions (visible to the AI) **MUST** describe purpose, parameters, response shape, common pitfalls, and rate-limit considerations. |
| `MCP-106` | Tool responses **MUST** include source attribution — an AI tool consumer **MUST** be able to report "this fact came from PuppetDB at timestamp X" if asked. |

### 17.1.3 Cacheability and rate limiting

| ID | Requirement |
|----|-------------|
| `MCP-201` | MCP tool responses **MUST** be cacheable and efficient. AI agents will issue many queries; the platform **MUST NOT** flood upstream APIs as a result. |
| `MCP-202` | The MCP server **MUST** apply per-principal rate limiting to prevent runaway AI loops from overwhelming the platform. In multi-node deployments, rate limits **MAY** be enforced per-node rather than globally; the platform **MUST** document the enforcement scope so operators can size limits appropriately. Cluster-wide enforcement **MAY** be provided via a coordinated backend and **MUST NOT** be represented as the default. |
| `MCP-203` | MCP tool responses **MUST** be RBAC-filtered at construction time against the requesting principal's permission scope, using the same shared integration cache and presentation-time filtering model as the web UI (see `CACHE-006`). An AI agent **MUST NOT** receive data outside its principal's permitted scope. Per-principal cache entries are not used — the shared cache is filtered before the response is returned. |

### 17.1.4 Authentication and authorization

| ID | Requirement |
|----|-------------|
| `MCP-301` | The MCP server **MUST** require authentication. Unauthenticated access is forbidden. |
| `MCP-302` | The MCP server **MUST** authenticate via the same mechanisms as the rest of the platform: API token, OIDC bearer, or whatever the platform supports for programmatic access. |
| `MCP-303` | The MCP server **MUST** enforce the same RBAC as the web UI. Tool access **MUST** be governed by the principal's roles. |
| `MCP-304` | The platform **MUST** support a dedicated **MCP role** that can be assigned to service accounts used by AI agents — typically more restricted than human-operator roles. |
| `MCP-305` | Audit trail entries **MUST** be created for MCP tool invocations, attributed to the principal, identifying the tool and its parameters (with secrets redacted). |

### 17.1.5 Tool catalog (initial set)

The initial MCP tool set is read-only and **MUST** include at minimum:

| Tool | Purpose |
|------|---------|
| `list_nodes` | Paginated list of inventory with filters (group, source, status, fact match) |
| `get_node` | Detailed view of a single node (identity, source attribution, group membership, summary status) |
| `get_node_facts` | Facts for a node, scoped by source if requested |
| `list_groups` | Groups with member counts and source attribution |
| `get_group_members` | Nodes in a given group |
| `list_journal_entries` | Filterable journal feed (per node, per group, time-range, type, source) |
| `get_report` | Detailed report by report identifier — covers all integrations that provide the Reports capability (Puppet run reports, vulnerability scans, etc.), with source attribution |
| `list_reports` | Filtered list of reports per node and time range — integration-agnostic; results are attributed per source integration |
| `get_integration_status` | Per-integration health summary: overall status, per-capability health, last-success timestamps, and active error messages for each configured integration |
| `get_recent_executions` | Read-only execution history (transcripts where allowed by RBAC) |

| ID | Requirement |
|----|-------------|
| `MCP-401` | The platform **MUST** expose at least the tools listed above at general availability. |
| `MCP-402` | Tools **MUST** carry input validation — an AI agent passing malformed parameters **MUST** receive a structured error explaining the failure. |
| `MCP-403` | Tools **MUST** declare their cost (cheap, moderate, expensive) in their description so AI agents can plan accordingly. |
| `MCP-404` | New tools **MAY** be added without breaking existing ones — the catalog is evolvable. |

### 17.1.6 Limits

| ID | Requirement |
|----|-------------|
| `MCP-501` | The MCP server **MUST** apply per-tool maximum result sizes to prevent context overflow on the consumer side. |
| `MCP-502` | When a result exceeds the maximum, the tool **MUST** return a partial result with a continuation token, not an error. |
| `MCP-503` | The MCP server **MUST** apply request timeout, identical to the platform's per-integration timeouts. |
| `MCP-504` | The MCP server **MUST** survive AI client disconnect mid-query without leaking server-side resources. |

## 17.2 Embedded AI-assisted inference

These features are in-product, triggered by specific UI entry points with pre-crafted prompts. They are **not** a general-purpose chat interface.

### 17.2.1 Scope

| ID | Requirement |
|----|-------------|
| `AI-001` | Embedded AI features **MUST** be triggered by specific UI entry points (buttons, menu items) with pre-crafted prompts optimized for infrastructure context. |
| `AI-002` | The platform **MUST NOT** expose a free-form chat interface as part of the embedded AI features. |
| `AI-003` | Embedded AI features **MUST** be optional and **MUST** be gracefully absent when no LLM key is configured. |
| `AI-004` | Embedded AI features **MUST NOT** be required for any core flow — the system **MUST** be fully usable without them. |

### 17.2.2 Bring-your-own-keys

| ID | Requirement |
|----|-------------|
| `AI-101` | The platform **MUST** support bring-your-own-keys for LLM access — administrators configure their own API keys for one or more providers. |
| `AI-102` | The platform **MUST** support multiple providers concurrently — at minimum: OpenAI, Anthropic, and a generic OpenAI-compatible endpoint (covers self-hosted and many third-party gateways). |
| `AI-103` | Per-feature provider selection **MAY** be supported — e.g., use one provider for analysis, another for reports — at administrator discretion. |
| `AI-104` | LLM API keys **MUST** be handled through the platform's secrets-aware mechanism. |
| `AI-105` | The platform **MUST NOT** ship a default LLM key, **MUST NOT** route through Vigil's own infrastructure, and **MUST NOT** retain a copy of any key it does not need. |

### 17.2.3 Feature set (initial)

The initial embedded AI features **MUST** include at minimum:

| Feature | Trigger | Purpose |
|---------|---------|---------|
| **Analyze recent failures** | Button on node detail | Summarize the last N failed events / reports for this node, identify common patterns, suggest likely causes |
| **Summarize configuration drift** | Button on node detail | Compare desired vs. observed state, highlight notable mismatches |
| **Explain this node's event history** | Button on node journal | Narrative summary of recent journal entries with grouping |
| **Weekly change summary** | Report generator | Cross-node summary of significant changes in the past week |
| **Nodes at risk** | Report generator | Pattern-based identification of nodes likely heading for trouble |
| **Unused resources** | Report generator | Hiera keys never consumed, idle cloud instances, etc. |
| **Smart suggestions** | Contextual surface in journal / detail views | "These 3 nodes have the same failure pattern — likely related" |

| ID | Requirement |
|----|-------------|
| `AI-201` | Each feature **MUST** be implementable without user-authored prompts — the prompt is embedded in the feature, optimized for the data shape. |
| `AI-202` | Each feature **MUST** present its output as structured content — bullets, tables, link-back to source data — not as opaque prose. |
| `AI-203` | Each feature **MUST** clearly mark AI-generated content as such, with the model and timestamp visible. |
| `AI-204` | Each feature **MUST** allow the user to inspect the data that was sent to the LLM (with secrets redacted) — for trust, debugging, and incident review. |

### 17.2.4 RBAC and data scoping

| ID | Requirement |
|----|-------------|
| `AI-301` | All AI inputs **MUST** be constructed from data the requesting user already has permission to see. The platform **MUST NOT** broaden the user's view by routing through AI. |
| `AI-302` | The platform **MUST NOT** include other users' private data, RBAC-restricted data, or system secrets in any prompt. |
| `AI-303` | Secret redaction **MUST** use structured annotation as the primary mechanism: fields declared `secret?: true` in a plugin's configuration schema or data model **MUST** be masked before any AI prompt is constructed, regardless of whether they appear in canonical key paths or unexpected contexts (nested payloads, free-form fact values, execution transcripts). Pattern-based (regex) redaction is a **backstop only** — applied to opaque string values from sources that lack structural secret marking, to catch known secret shapes (PEM blocks, cloud-provider access-key prefixes, JWT-like tokens, API-key prefixes). The platform **MUST NOT** rely on regex as the primary filter. The set of regex backstops **MUST** be configurable and **MUST** cover at minimum AWS, GCP, Azure, and generic bearer-token patterns. |
| `AI-304` | The platform **MUST NOT** persist AI-generated output as authoritative data. AI output is presentation, not source of truth. |
| `AI-305` | AI feature usage **MUST** be auditable — an audit trail entry records the user, feature, and timestamp (but not the full prompt content unless administrator opts in to detailed logging). |

### 17.2.5 Failure handling

| ID | Requirement |
|----|-------------|
| `AI-401` | LLM call failures (timeout, rate limit, provider error) **MUST NOT** affect non-AI functionality. The user receives an actionable error and the rest of the system continues normally. |
| `AI-402` | The platform **MUST** apply timeouts to LLM calls and **MUST** support per-provider concurrency limits to avoid cost overruns. |
| `AI-403` | The platform **MUST** report estimated token usage per AI feature invocation so administrators can evaluate cost before enabling at scale. |
| `AI-404` | The platform **MAY** cache AI responses keyed on the underlying input data — when the same Hiera state is re-analyzed by the same user within a TTL, return the cached response. |

### 17.2.6 Quality and trust

| ID | Requirement |
|----|-------------|
| `AI-501` | The platform **MUST NOT** position AI output as authoritative. UI copy **MUST** include language like "AI-generated insight; verify before acting." |
| `AI-502` | When an AI feature offers an actionable suggestion (e.g., "consider rebooting this node"), the action **MUST** still pass through the regular RBAC and security controls. AI does not bypass policy. |
| `AI-503` | The platform **MUST** support administrator-level disable of all AI features as a single switch, and per-feature disables for fine-grained control. |
| `AI-504` | The platform **MUST NOT** auto-trigger AI features on user actions without an explicit click — no implicit AI calls. |

## 17.3 Future AI surfaces (out of scope for the initial AI release)

These are explicitly **not** in scope for the first AI release. They may be revisited later but are noted here so they are not assumed to be present:

- General-purpose chat interface
- AI-driven autonomous remediation (acting without human approval)
- Training of custom models on user data
- Cross-tenant inference or fine-tuning
- Voice / multimodal interfaces

| ID | Requirement |
|----|-------------|
| `AI-601` | The platform **MUST NOT** ship the surfaces listed above in the initial AI release. |
| `AI-602` | If any of these surfaces is added later, it **MUST** receive a separate scope amendment to this document. |

---

[← Previous: Testing Philosophy](16-testing-philosophy.md) | [Next: UI Requirements →](18-ui-requirements.md)

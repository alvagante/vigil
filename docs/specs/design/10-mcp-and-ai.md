# 10. MCP Server & AI-Assisted Inference

This section realizes PRD section 17. Two surfaces, related but distinct:

- **MCP server:** read-only tools exposed to external AI agents. Same RBAC. Structured, token-efficient responses.
- **Embedded AI inference:** in-product analysis features triggered by specific UI buttons, using user-configured LLM providers.

## 10.1 MCP server

### 10.1.1 Wire transport

The Model Context Protocol has multiple transports; the most widely adopted for remote servers is **HTTP+JSON-RPC over SSE** (server-sent events) for tool invocations and notifications. We expose:

```
POST /mcp/v1/rpc        — JSON-RPC 2.0 envelope for tool calls
GET  /mcp/v1/events     — SSE stream for notifications (optional Phase 2)
```

The endpoint is a separate Phoenix pipeline from the web UI, authenticated via API token only (`MCP-301`, `MCP-302`). It does not accept cookies or participate in the session-auth flow.

> **Decision: HTTP+JSON-RPC, not the `stdio` transport.**
> `stdio` is used by MCP for local subprocess servers. Vigil is a server-side application; remote HTTP is the fit. We keep the protocol format and tool semantics aligned with MCP's spec so off-the-shelf MCP clients work.

### 10.1.2 Tool registration

Each MCP tool is a module implementing `Vigil.MCP.Tool`:

```elixir
defmodule Vigil.MCP.Tool do
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()         # JSON Schema
  @callback cost() :: :cheap | :moderate | :expensive
  @callback permissions_required() :: [String.t()]
  @callback call(principal, args, opts) ::
    {:ok, Vigil.MCP.Response.t()} | {:error, Vigil.MCP.Error.t()}
end
```

The MCP server registers tools at boot:

```elixir
defmodule Vigil.MCP.Registry do
  def all, do: [
    Vigil.MCP.Tools.ListNodes,
    Vigil.MCP.Tools.GetNode,
    Vigil.MCP.Tools.GetNodeFacts,
    Vigil.MCP.Tools.ListGroups,
    Vigil.MCP.Tools.GetGroupMembers,
    Vigil.MCP.Tools.ListJournalEntries,
    Vigil.MCP.Tools.GetReport,
    Vigil.MCP.Tools.ListReports,
    Vigil.MCP.Tools.GetHealth,
    Vigil.MCP.Tools.GetRecentExecutions
  ]
end
```

The tool set matches `MCP-401` exactly. Adding tools is additive (`MCP-404`).

### 10.1.3 Tool invocation path

```
Client → POST /mcp/v1/rpc
  │
  ├── VigilWeb.MCPPipeline (token auth, rate limit, request timeout)
  ├── VigilWeb.MCPController.dispatch/2
  │      resolves method → tool module
  ├── Vigil.MCP.Dispatcher.call(principal, tool, args)
  │      ├── validates args against tool's input_schema
  │      ├── RBAC check against tool's permissions_required
  │      ├── telemetry span
  │      ├── applies per-principal rate limiter
  │      ├── tool.call(principal, args, opts)
  │      └── shapes response with pagination / continuation
  ├── Audit entry (MCP-305)
  └── Response back to client
```

### 10.1.4 Response shape

Responses are structured JSON with pagination built in:

```json
{
  "data": [
    {
      "id": "node-uuid",
      "name": "web-prod-01",
      "sources": ["puppet:puppet-prod", "aws:aws-main"],
      "status": "active",
      "groups": ["production", "webservers"]
    }
  ],
  "pagination": {
    "next_cursor": "eyJpZCI6...",
    "has_more": true
  },
  "metadata": {
    "fetched_at": "2026-05-06T12:00:00Z",
    "partial": false,
    "missing_sources": []
  }
}
```

Every response carries `fetched_at` (source attribution timestamp per `MCP-106`), optional `partial` marker, and cursor for continuation. The shape is consistent across tools so AI tooling can type-check (`MCP-102`).

### 10.1.5 Per-tool limits and pagination

`MCP-501`, `MCP-502`: each tool enforces a maximum result size. Beyond the limit, a `next_cursor` is returned. The client passes it back in the next call.

Size limits default to conservative values appropriate for AI context windows:

- `list_nodes`: max 100 per page
- `get_node_facts`: single node, but facts payload capped at 64KB; oversized facts paginated by key prefix
- `list_journal_entries`: max 50 per page
- `list_reports`: max 50 per page

### 10.1.6 RBAC enforcement

Tools run under the token's principal. The same `Vigil.Core.RBAC.Evaluator` used for the web UI is used here (`MCP-303`, `NFR-301`). A token scoped to `mcp:*` with role `mcp-service`:

- Can read inventory, facts, journal on integrations permitted to the role.
- Cannot execute commands, provision, or configure anything.
- Cannot access other users' private data.

MCP tools use the same shared, unfiltered integration cache as the web UI (`MCP-203`, `CACHE-006`). A tool constructs its response only after applying the token principal's compiled RBAC target-scope filter, so an admin and a narrower MCP service account may hit the same cache entry but never receive the same filtered payload unless their scopes match. MCP filtering follows the same `RBAC-110` constraint as the web UI: resolve effective scope once, then filter cached records through bounded membership or indexed predicate checks.

### 10.1.7 Rate limiting

`MCP-202` requires per-principal rate limiting. Implementation via a token bucket keyed on principal:

```elixir
defmodule Vigil.MCP.RateLimiter do
  def check(principal_id) do
    case Hammer.check_rate("mcp:#{principal_id}", 60_000, 120) do
      {:allow, _count} -> :ok
      {:deny, _} -> {:error, :rate_limited}
    end
  end
end
```

Defaults: 120 requests per minute per principal; configurable per token on issuance.

> **Decision: Rate limits are enforced per-node in multi-node deployments.**
> `Hammer`'s default backend is ETS — in-process, per-node. In a 3-node cluster, a principal can make up to `3 × 120 = 360` requests per minute before any single node rate-limits them. Per `MCP-202`, the platform documents this enforcement scope rather than paying the cost of a cluster-wide coordinated limiter.
>
> Cluster-wide enforcement would require either a distributed counter (Redis — explicitly excluded from the stack) or a Postgres-backed Hammer (adds a per-request DB write on the hot auth path, degrading latency for all MCP calls). For the target deployment scale (10 users, 3-node max for HA), the per-node effective limit is the correct tradeoff.
>
> Two mitigations take the edge off the per-node characteristic: (1) operators sizing cluster-aware limits should set per-node limits to `expected_global / node_count` rather than `expected_global`, and (2) the same load-balancer affinity on principal ID that improves cache hit rates (see design/05 §5.11.2) also reduces the rate-limit dilution — stuck-to-one-node principals get the expected global limit.
>
> For EE deployments requiring strict cluster-wide enforcement (e.g., per-tenant API quotas as part of FS EE-8 multi-tenancy), a distributed Hammer backend over PostgreSQL may be shipped as an EE optional extension. That is not committed work at this stage.

### 10.1.8 Tool descriptions

Each tool's `description/0` follows a format optimized for AI consumption (`MCP-105`):

```elixir
def description do
  """
  Retrieve a paginated list of managed nodes across all enabled integrations.

  Use this to find specific nodes by fact, group, or source. Results are
  deduplicated across sources and include attribution for which integrations
  report each node.

  Parameters:
    - filter: optional filters (group, source, status, fact_match)
    - cursor: continuation token for pagination
    - limit: max results per page (default 50, max 100)

  Response: list of node records. Each record includes the node's canonical
  name, identity attributes, current status, and source integrations.

  Cost: cheap — primarily served from cache at most scales.

  Rate-limited per principal; respect the rate-limit headers in responses.
  """
end
```

`MCP-403` requires cost declaration. Cost is a coarse hint — cheap, moderate, expensive — so agents can plan (e.g., cache results, avoid tight loops).

### 10.1.9 Future write-side tools (`MCP-003`)

The architecture permits future write-side tools (execute commands, start provisioning). When introduced:

- They require a separate permission family (`mcp:tool:execute:*`) not granted by default.
- They pass through the same execution / provisioning pipeline as the web UI — no MCP-specific shortcut.
- They respect the per-action RBAC, allowlists, and per-target scoping that apply to the principal.

`MCP-004` (no configuration management via MCP) is enforced by simply not implementing configuration tools. The registry exposes only the intended set.

## 10.2 Embedded AI inference

This is a distinct surface from MCP. It runs inside Vigil's UI, using admin-configured LLM providers, to produce contextual summaries and analyses.

### 10.2.1 Provider abstraction

```elixir
defmodule Vigil.AI.Provider do
  @callback name() :: String.t()
  @callback generate(config :: map(), prompt :: map(), opts :: keyword()) ::
    {:ok, %{text: String.t(), tokens: integer()}} | {:error, term()}
end

defmodule Vigil.AI.Providers.OpenAI, do: @behaviour Vigil.AI.Provider
defmodule Vigil.AI.Providers.Anthropic, do: @behaviour Vigil.AI.Provider
defmodule Vigil.AI.Providers.OpenAICompatible, do: @behaviour Vigil.AI.Provider
```

`AI-102` requires at minimum OpenAI, Anthropic, and a generic OpenAI-compatible endpoint. The compatible endpoint covers self-hosted LLMs (Ollama, vLLM, LocalAI), gateway proxies (Portkey, OpenRouter), and Azure OpenAI.

Provider config is stored per-tenant in `settings`, with API keys as secret refs:

```json
{
  "providers": {
    "primary":   {"type": "anthropic",         "model": "claude-sonnet-4.5", "api_key_ref": "secret:uuid"},
    "secondary": {"type": "openai_compatible", "endpoint": "http://ollama:11434/v1",
                  "model": "llama3.1:70b", "api_key_ref": "secret:uuid"}
  },
  "feature_providers": {
    "analyze_failures": "primary",
    "explain_events": "secondary"
  }
}
```

Per-feature provider selection (`AI-103`) is optional.

### 10.2.2 Feature architecture

Each feature is a module implementing `Vigil.AI.Feature`:

```elixir
defmodule Vigil.AI.Feature do
  @callback id() :: atom()
  @callback name() :: String.t()
  @callback ui_trigger() :: %{section: atom(), label: String.t()}
  @callback permission() :: String.t()
  @callback collect_context(principal, params) :: {:ok, context} | {:error, term}
  @callback render_prompt(context) :: prompt  # shape depends on provider
  @callback render_output(llm_response, context) :: Phoenix.LiveView.Rendered.t()
end
```

The `collect_context/2` callback is responsible for:

- Fetching the input data through existing contexts (so RBAC applies — `AI-301`).
- Redacting secrets (`AI-303`).
- Shaping to a compact structure for the prompt.

The `render_prompt/1` callback produces the final prompt. Prompts are not user-authored (`AI-201`). They are embedded in the feature module and optimized for the data shape.

### 10.2.3 Initial features

Per `AI-201..204`, the initial set:

| Feature id | Trigger | Module |
|-----------|---------|--------|
| `analyze_failures` | Button on node detail | `Vigil.AI.Features.AnalyzeFailures` |
| `summarize_drift` | Button on node detail | `Vigil.AI.Features.SummarizeDrift` |
| `explain_events` | Button on node journal | `Vigil.AI.Features.ExplainEvents` |
| `weekly_change_summary` | Reports page | `Vigil.AI.Features.WeeklyChangeSummary` |
| `nodes_at_risk` | Reports page | `Vigil.AI.Features.NodesAtRisk` |
| `unused_resources` | Reports page | `Vigil.AI.Features.UnusedResources` |
| `smart_suggestions` | Contextual in journal / detail | `Vigil.AI.Features.SmartSuggestions` |

Each feature is a LiveComponent embedded in the relevant page. It shows a "Run analysis" button gated by the feature's permission (`AI-502` — RBAC still applies).

### 10.2.4 Secret redaction

Per `AI-303`, secret redaction uses **structured annotation as the primary mechanism** and regex as a backstop. Plugin config schemas mark fields `secret?: true` (see design/03 §3.2.3); fact and event payloads carry optional `__secret_path__` markers that `Vigil.Core.Secrets.Redactor` strips before any prompt is constructed. Regex is applied afterwards, as a second pass, to catch secrets that slipped into opaque string fields from sources that lack structural marking.

```elixir
defmodule Vigil.AI.Redactor do
  @doc """
  Applied in order:
    1. Structured redaction — walk the context, mask every value at a known secret path
       (per plugin schema annotations) and every key matching a configured deny-list
       of known-sensitive key names.
    2. Pattern redaction — only on opaque string values remaining after step 1, mask
       substrings matching well-known secret patterns.

  Step 1 is the primary mechanism. Step 2 is a backstop for unstructured sources.
  """
  def scrub(context) do
    context
    |> scrub_structured(schema_registry())
    |> scrub_patterns(pattern_registry())
  end

  defp scrub_structured(context, schemas) do
    Vigil.Core.Traverse.map_leaves(context, fn path, value ->
      cond do
        path_is_secret?(path, schemas) -> redacted_marker(:schema_annotated)
        key_name_sensitive?(path)      -> redacted_marker(:sensitive_key_name)
        true                            -> value
      end
    end)
  end

  defp scrub_patterns(context, patterns) do
    Vigil.Core.Traverse.map_leaves(context, fn
      _path, bin when is_binary(bin) -> apply_patterns(bin, patterns)
      _path, value -> value
    end)
  end

  # The key-name deny list catches common accidents:
  # values under keys named "password", "api_key", "secret", "token", "private_key",
  # etc. get redacted regardless of content shape.
  @sensitive_key_names ~w(password api_key secret token private_key bearer_token
                          access_key secret_access_key client_secret)
end
```

**Pattern registry (`AI-303` backstop).** The regex patterns are deliberately broad and maintained by platform operators rather than hard-coded at release:

```elixir
defmodule Vigil.AI.Redactor.Patterns do
  @builtin [
    # Cloud provider access keys
    {:aws_access_key,    ~r/\bAKIA[0-9A-Z]{16}\b/},
    {:aws_session_token, ~r/\bASIA[0-9A-Z]{16}\b/},
    {:gcp_api_key,       ~r/\bAIza[0-9A-Za-z_-]{35}\b/},
    {:azure_storage_key, ~r/\b[A-Za-z0-9+\/]{86}==\b/},

    # Generic formats
    {:pem_block,         ~r/-----BEGIN [A-Z ]+PRIVATE KEY-----[\s\S]+?-----END [A-Z ]+PRIVATE KEY-----/},
    {:github_pat,        ~r/\bghp_[A-Za-z0-9]{36}\b/},
    {:openai_key,        ~r/\bsk-[A-Za-z0-9]{32,}\b/},
    {:slack_token,       ~r/\bxox[baprs]-[A-Za-z0-9-]+\b/},

    # Bearer / JWT — kept deliberately specific to reduce false positives on
    # arbitrary base64 payloads. Only matches three-segment tokens in contexts
    # where the prefix or header suggests JWT.
    {:jwt_bearer,        ~r/\bBearer\s+eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/}
  ]

  def all(), do: @builtin ++ operator_defined_patterns()
end
```

Key points:

- **Structure-first order is decisive.** If a plugin declares `password` as a secret field in its schema, the value is masked by annotation before any regex ever sees it. This catches the "secret in an unexpected place" class of bug — `:schema_annotated` mask fires even if the value is inside a nested struct or a free-form log line that the regex wouldn't match.
- **Key-name deny list catches free-form maps.** Facts and events from plugins lacking rigorous schema marking still get protection if their keys look obviously sensitive.
- **Regex is not the first filter.** The previous design privileged regex patterns — their coverage gaps (loose JWT matching false-positives on base64 facts, PEM regex requires contiguous string) produced both false positives and false negatives. Moving regex behind the structured layer makes regex a high-precision low-frequency tool instead of a high-recall first pass.
- **JWT pattern is restricted.** The unrestricted `eyJ...` pattern was a known false-positive generator — plenty of fact payloads contain base64 blobs starting with `eyJ` that are not tokens. The restricted pattern requires the `Bearer ` prefix, which eliminates most false positives at the cost of missing raw JWTs in opaque fields. Those raw JWTs get caught by the structured layer if the plugin marks them, or by the key-name deny list if they're stored under a recognisable key. If they're in truly unstructured fact-blob text, we accept the gap as preferable to a broader pattern that redacts legitimate payloads.
- **PEM pattern handles structured fields.** The PEM regex still requires a contiguous block, but the structured-first pass protects PEM content stored in a `private_key` field regardless of serialization.
- **GCP and Azure covered.** The previous design covered only AWS. GCP API keys (`AIza` prefix) and Azure storage connection strings now have patterns.
- **Operator-defined patterns.** Site-specific token formats (internal API keys, vendor-specific credentials) can be added via configuration without a code change.

**Test coverage** (`TEST-801`, `TEST-802`) asserts:

1. A value marked `secret?: true` in a plugin schema is masked even when it appears in unexpected nested paths.
2. A value stored under a `@sensitive_key_names` key is masked regardless of content.
3. Each built-in regex masks correctly and does not over-mask documented false-positive candidates.
4. A synthetic context seeded with representative secrets (structured + unstructured) has no unredacted secret after `scrub/1`.

### 10.2.5 Data scoping and inspection (`AI-304`, `AI-204`)

Before calling the LLM, the redacted context is recorded alongside the feature invocation so the user can inspect what was sent (with secrets already masked). Users can click "show what was sent" to view the exact input.

LLM output is rendered but *not persisted as authoritative data* — it's presentation. We cache responses in memory keyed on `{feature, context_hash, user_id}` with a short TTL (`AI-404`) so re-opening the same analysis is instant.

### 10.2.6 Failure handling

`AI-401..404`: LLM call failures do not affect non-AI functionality.

```elixir
defmodule Vigil.AI.Invoker do
  def invoke(feature_id, principal, params) do
    feature = registry.fetch(feature_id)

    with :ok <- RBAC.check(principal, feature.permission(), params),
         {:ok, context} <- feature.collect_context(principal, params),
         context <- Redactor.scrub(context),
         prompt <- feature.render_prompt(context),
         :ok <- audit_invocation(principal, feature_id),
         {:ok, response} <- provider.generate(config, prompt, timeout: 30_000) do
      {:ok, feature.render_output(response, context)}
    else
      {:error, {:llm, reason}} -> {:error, friendly_message(reason)}
      err -> err
    end
  end
end
```

Provider calls have explicit timeouts. Per-provider concurrency limits (`AI-402`) come from the provider config. Token usage (`AI-403`) is reported in telemetry and shown in the UI with a note "this analysis used ~1,800 tokens."

### 10.2.7 Graceful absence

`AI-003`, `AI-004`, `AI-503`:

- When no provider is configured, AI feature buttons are hidden.
- The global "disable AI" setting hides all buttons and blocks any programmatic invocation.
- Per-feature disables (via settings) hide individual buttons.

### 10.2.8 UI treatment

AI-generated content is visually marked (`AI-203`, `AI-501`):

```heex
<div class="ai-output" role="region" aria-label="AI-generated analysis">
  <div class="ai-meta">
    <span class="badge">AI-generated</span>
    <span>Model: {@model}</span>
    <span><.time datetime={@generated_at} /></span>
    <span>~{@tokens} tokens</span>
    <button phx-click="show_source_data">Show input data</button>
  </div>
  <.rendered_output value={@output} />
  <p class="ai-disclaimer">AI-generated insight. Verify before acting.</p>
</div>
```

`AI-504` is honored — no implicit triggering. Every invocation requires a click.

### 10.2.9 AI call RBAC

`AI-502`: if an AI feature suggests an action (e.g., "reboot this node"), the user still has to click through the normal execute flow, which passes through RBAC. AI does not bypass policy.

For MCP + AI combined flows (AI agent using MCP), the agent's principal has its own roles; the actions it can take are exactly those its roles permit. No AI privilege inherits from the suggestion surface.

### 10.2.10 Out of scope for this release

Per `AI-601`, explicitly not implemented:

- Free-form chat interface.
- Autonomous remediation (AI taking action without approval).
- Fine-tuning or training on user data.
- Multi-tenant cross-pollination of prompts.
- Voice / multimodal.

These are excluded by not building them; the architecture doesn't preclude adding them later under a scope amendment.

## 10.3 Testing MCP + AI

- **MCP tool shape conformance** — each tool's response validates against its declared schema. Automated in CI.
- **MCP RBAC** — test that a token scoped to `mcp-service` can invoke read tools but can't reach data outside its role's scope.
- **MCP rate limiting** — property-based test confirming that N+1 calls in a minute fail with 429.
- **AI redaction** — inject known secrets into feature contexts, verify the LLM never sees them (asserted on a mock provider).
- **Graceful absence** — test that the UI renders normally with no providers configured.
- **Per-feature disable** — test that disabled features don't appear in the UI.

## 10.4 Cost governance

Production AI usage costs accumulate quickly. We ship with:

- Per-feature token counters in telemetry.
- A daily rollup report in the admin dashboard.
- Optional token-budget caps per provider, after which further calls return "budget exhausted" error for the day.

Admins can inspect which features are producing the most token usage and disable expensive ones.

---

[← Previous: LiveView UI](09-liveview-ui.md) | [Next: Puppet Integration →](11-puppet-integration.md)

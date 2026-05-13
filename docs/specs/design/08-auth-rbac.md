# 8. Authentication & RBAC

This section realizes PRD `AUTH-*`, `RBAC-*`, `NFR-201..301..604`. It covers local authentication and single-IdP OIDC (CE), SAML/LDAP/multi-IdP (EE), session and token handling, and the permission evaluation engine that gates every user-facing action and MCP tool call. The edition split is covered in-line where it affects implementation; see [`docs/specs/editions.md`](../editions.md) for the commercial rationale.

## 8.1 Authentication strategy

Phoenix's `phx.gen.auth` generator gives us a solid starting point for local auth. We extend it with pluggable external providers.

> **Edition boundary:** Local auth + API tokens + single-IdP OIDC ship in CE (`AUTH-001..009`, `AUTH-051..057`). SAML, LDAP, multi-IdP OIDC, wildcard group mapping, and IdP group re-evaluation on every login are EE features (`AUTH-101..110`) delivered by `vigil_enterprise` via the `Vigil.Auth.Provider` extension point. CE ships the `Vigil.Auth.Provider` behaviour and a `Vigil.Auth.Providers.Local` + `Vigil.Auth.Providers.OIDC` implementation; EE adds `Vigil.Auth.Providers.SAML`, `Vigil.Auth.Providers.LDAP`, and the multi-IdP orchestration layer.

### 8.1.1 Local authentication (CE)

The generated auth layer provides:

- `/users/register`, `/users/log_in`, `/users/log_out`, `/users/reset_password` routes
- Argon2 password hashing
- Session-based auth via signed cookies
- Password reset via token+email

Extensions we add:

- **Rate limiting** (`NFR-202`) via `Hammer` or custom ETS-based limiter per username and per IP.
- **Account lockout** (`NFR-203`) after N failures within a window, tracked in the `users.status` column.
- **Session lifetime controls** (`NFR-204`) — configurable absolute and idle timeouts applied in the session plug.
- **Debounced session-activity writes** (`AUTH-010`) — see §8.2 below.
- **Audit trail on auth events** — every login, logout, lockout, password change produces an `audit_entries` row.

### 8.1.2 OIDC authentication (CE)

CE ships a minimal OIDC profile — single IdP, literal (exact-match) group-to-role mapping, no wildcard patterns, no IdP re-evaluation on every login. This covers the "our team uses Google / GitHub / Keycloak / Azure-AD-as-OIDC SSO" case for small self-hosted deployments.

Implementation uses `openid_connect` directly (a well-maintained Elixir library with a minimal dependency footprint) rather than pulling in the full `Ueberauth` umbrella. The library handles discovery, JWKS refresh, ID token validation, and PKCE. We wrap it in a `Vigil.Auth.Providers.OIDC` module implementing the `Vigil.Auth.Provider` behaviour.

```elixir
defmodule Vigil.Auth.Provider do
  @callback authenticate(params :: map()) :: {:ok, auth_result} | {:error, term()}
  @callback refresh_user(user :: User.t()) :: {:ok, User.t()} | {:error, term()}
  @callback id() :: atom()
  @callback display_name() :: String.t()
  # ...
end
```

The OIDC callback controller:

```elixir
def callback(conn, %{"code" => code, "state" => state}) do
  with {:ok, tokens} <- OpenIDConnect.fetch_tokens(:primary_oidc, %{code: code}),
       {:ok, claims} <- OpenIDConnect.verify(:primary_oidc, tokens["id_token"]),
       {:ok, user} <- upsert_external_user(:primary_oidc, claims),
       :ok <- apply_literal_group_mappings(user, claims["groups"] || []),
       {:ok, session} <- start_session(user) do
    conn
    |> put_session(:token, session.token)
    |> redirect(to: "/")
  end
end
```

**JIT provisioning** (`AUTH-052`): `upsert_external_user/2` creates the user record on first successful login. Lookup key is `(tenant_id, auth_source = "oidc:primary", external_subject = claims["sub"])`.

**Literal group mapping** (`AUTH-053`): `apply_literal_group_mappings/2` matches each IdP group to a configured mapping row where `group_pattern` is stored as a literal string (not a wildcard). CE enforces a constraint on the `group_role_mappings` table that the `group_pattern` column contains no wildcard characters when `idp` is a CE OIDC provider (see §8.3.5).

**On-demand refresh** (`AUTH-053` covers the CE minimum): administrators can trigger "refresh user from IdP" per user, which re-authenticates the user's groups against the IdP and re-applies mappings. CE does **not** re-evaluate groups on every login. EE does (`AUTH-109`).

**CE single-IdP constraint** (`AUTH-057`): the CE implementation rejects configuration of a second OIDC provider. The settings UI hides the "add provider" action when CE is running; the configuration API returns `{:error, :ee_required}`.

### 8.1.3 Enterprise external authentication (EE)

Implemented in `vigil_enterprise` as a set of providers registered into the same `Vigil.Auth.Provider` extension point:

- `Vigil.Auth.Providers.SAML` — via `Samly`. Handles SP-initiated flows, SAML assertions, attribute mapping, multi-IdP configuration.
- `Vigil.Auth.Providers.LDAP` — via `Exldap` wrapped in a `NimblePool` of bind connections (see §8.1.4 below).
- `Vigil.Auth.Providers.EnterpriseOIDC` — extends the CE OIDC provider with multi-IdP support (several concurrent OIDC IdPs), wildcard group patterns, and re-evaluation on every login.

The EE auth orchestrator runs ahead of the provider modules and decides which provider should handle a given login based on:

- Route (`/auth/saml/:idp/request`, `/auth/oidc/:idp/request`)
- User hint in the login UI (email domain → provider)
- Break-glass local-auth fallback

All EE providers share the same `upsert_external_user/2` path used by CE OIDC. The difference is in group re-evaluation:

```elixir
defp reevaluate_roles_ee(user, idp_groups) do
  Repo.transaction(fn ->
    # Clear previously group-mapped assignments for this auth_source
    from(ur in UserRole,
      where: ur.user_id == ^user.id and like(ur.source, "group_mapped:%")
    )
    |> Repo.delete_all()

    # Apply current mappings, including wildcards
    for group <- idp_groups,
        mapping <- matching_mappings_with_wildcards(user.auth_source, group) do
      Repo.insert!(%UserRole{
        user_id: user.id,
        role_id: mapping.role_id,
        source: "group_mapped:#{group}"
      })
    end

    PermissionCache.invalidate(user.id)
  end)
end
```

Wildcard patterns (`AUTH-108`) are glob-to-regex translated once at mapping creation time — `vigil-*` compiles to `^vigil-[^/]*$`. The compiled regex is stored alongside the pattern for fast matching.

### 8.1.4 LDAP connection pooling (EE)

`Exldap` wraps Erlang's `:eldap`, which holds one connection per process. Under concurrent login load this creates a choice between:

- Serialising logins on a single connection (latency spikes under load)
- Opening a fresh connection per login (expensive LDAP bind; connection exhaustion on the LDAP server)

Neither is acceptable. The EE LDAP provider wraps `:eldap` in a `NimblePool`:

```elixir
defmodule Vigil.Auth.Providers.LDAP.ConnectionPool do
  @behaviour NimblePool

  def init_pool(opts), do: {:ok, opts}

  def init_worker(opts) do
    {:ok, conn} = :eldap.open(opts.hosts, opts.eldap_opts)
    :ok = :eldap.simple_bind(conn, opts.bind_dn, opts.bind_password)
    {:ok, conn, opts}
  end

  def handle_checkout(_from, _pool, conn, opts), do: {:ok, conn, conn, opts}
  def handle_checkin(_from, _pool, conn, opts), do: {:ok, conn, opts}

  def terminate_worker(_reason, conn, opts) do
    :eldap.close(conn)
    {:ok, opts}
  end
end

def authenticate(username, password) do
  NimblePool.checkout!(__MODULE__, :checkout, fn _from, conn ->
    case :eldap.simple_bind(conn, user_dn(username), password) do
      :ok -> {:ok, lookup_user(conn, username)}
      {:error, _} = err -> err
    end
  end, timeout: 5_000)
end
```

Pool size defaults to `2 * expected_concurrent_logins`, configurable per integration. Idle connections are rotated periodically so the pool survives LDAP server restarts without operator intervention.

Connection-level binding (service account) is separate from user-level binding (login). The pool holds service-account connections; user logins do a transient `simple_bind` on a checked-out connection, then re-bind as the service account on checkin. This keeps the pool homogeneous and safe to reuse.

### 8.1.5 API tokens (`AUTH-005`)

Tokens are created by users (or admins on behalf of users) for programmatic access (CLI, MCP, automation):

```elixir
defmodule Vigil.Core.Accounts.APITokens do
  def mint(user, name, opts) do
    token = :crypto.strong_rand_bytes(32)
    encoded = Base.url_encode64(token, padding: false)
    token_hash = :crypto.hash(:sha256, encoded)

    %APIToken{}
    |> APIToken.changeset(%{
      user_id: user.id,
      name: name,
      token_hash: token_hash,
      scopes: opts[:scopes] || [],
      expires_at: opts[:expires_at]
    })
    |> Repo.insert!()

    {:ok, encoded}   # shown once; never recoverable
  end
end
```

Token authentication path:

```elixir
defmodule VigilWeb.TokenAuthPlug do
  def call(conn, _) do
    case get_token(conn) do
      nil -> conn
      token ->
        hash = :crypto.hash(:sha256, token)
        case Accounts.lookup_token(hash) do
          {:ok, token_record, user} ->
            touch_last_used(token_record)
            assign(conn, :current_user, user)
            |> assign(:auth_source, :token)
          :error -> conn
        end
    end
  end
end
```

Tokens carry the user's roles, with optional scopes that narrow permissions further (`AUTH-005`). An MCP-dedicated token is typically scoped to `mcp:*` permissions.

### 8.1.6 Default role for unmapped users (`RBAC-203`)

If a user's groups don't match any mapping, they either get the configured default role or, if set to "deny access," the login fails with a clear error: "your account has no role assignments — contact your administrator." This applies to both CE OIDC and EE providers.

### 8.1.7 Coexistence of local and external auth

`AUTH-055`, `AUTH-106`, `AUTH-110` are satisfied by:

- Local users remain authenticatable via their password hash.
- External users have `password_hash = NULL` and cannot log in locally.
- Break-glass local access remains available even when any IdP is down.
- In EE, an admin can disable local auth entirely via a setting (`AUTH-106`); the UI then shows only IdP login buttons. CE always keeps the break-glass admin account available as fallback.

Sessions for already-authenticated users continue to work when the IdP is unavailable (`AUTH-056`, `AUTH-110`); only *new* logins via that IdP fail.

### 8.1.8 The break-glass admin account (AUTH-009 / AUTH-106)

`AUTH-009` requires a canonical break-glass path that survives IdP failure. `AUTH-106` (EE) extends this with an explicit operator decision to disable local auth — including the break-glass account — in exchange for owning an out-of-band recovery path.

#### The protected user row

A single row in `users` is marked as the break-glass admin via a non-NULL `is_break_glass` flag (defaulted true on the seeded admin, NULL otherwise — a partial unique index enforces "at most one"):

```sql
ALTER TABLE users ADD COLUMN is_break_glass BOOLEAN;
CREATE UNIQUE INDEX users_break_glass_uniq ON users (tenant_id) WHERE is_break_glass IS TRUE;
```

The seed script (`priv/repo/seeds.exs`) ensures one such row exists per tenant on first boot. The platform refuses to start if the row is missing in CE — the absence is a critical-path configuration error, not a recoverable state.

#### Invariants enforced at the data layer

| Invariant | Enforcement |
|-----------|-------------|
| The break-glass account cannot be deleted | An Ecto changeset constraint rejects `delete/1` on a user with `is_break_glass = true`. A Postgres trigger raises on `DELETE FROM users WHERE is_break_glass = TRUE` as a defence-in-depth backstop. |
| The break-glass account cannot be bound to an external IdP | The changeset rejects any update that sets `auth_source` to anything other than `'local'` on the break-glass row. The row's `auth_source` is permanently `'local'`. |
| The break-glass account always retains the administrator role | A trigger on `user_roles` rejects any DELETE that would remove the last administrator role from a break-glass user. The "force" path requires a separate, audited maintenance command. |
| At most one break-glass account per tenant | The partial unique index above. Attempting to set `is_break_glass = true` on a second row violates the index. |

These rules apply to CE *always*. They apply to EE while local auth is enabled. When EE local auth is disabled via the `AUTH-106` setting, the break-glass row is preserved in the database but the auth path that consumes it is short-circuited — see [§8.1.8.4](#8184-ee-local-auth-disable-auth-106) below.

#### 8.1.8.1 Distinct audit marker

Every successful login produces an `audit_entries` row. Logins via the break-glass account additionally carry a marker in `params.break_glass = true` and a distinct action `auth.login.break_glass` (rather than the generic `auth.login`). The audit list view filters and styles these rows differently so a reviewer can identify break-glass use at a glance.

```elixir
defp record_login(user, conn) do
  action = if user.is_break_glass, do: "auth.login.break_glass", else: "auth.login"
  params = if user.is_break_glass, do: %{break_glass: true}, else: %{}

  Vigil.Core.Audit.write_finalized(user, action, :success,
                                   target_kind: "user", target_id: user.id,
                                   params: params, request_meta: request_meta(conn))
end
```

#### 8.1.8.2 Real-time admin alert

`AUTH-009`: every break-glass login fires an alert to currently-active administrator sessions via the `admin_alerts` PubSub topic, *and* emits a structured log entry at `:warn` so external observability tooling can route it:

```elixir
def handle_break_glass_login(user, conn) do
  Phoenix.PubSub.broadcast(Vigil.PubSub, "admin_alerts",
    {:break_glass_login, %{user_id: user.id, occurred_at: DateTime.utc_now(),
                            source_ip: get_peer(conn), user_agent: ua(conn)}})

  Logger.warning("Break-glass account used",
    event: "auth.break_glass.login",
    user_id: user.id,
    source_ip: get_peer(conn))
end
```

Active admin LiveViews (`HealthDashboardLive`, `SettingsLive`, etc. — anything mounted in the `:admin` `live_session`) subscribe to `admin_alerts` on mount and render an inline toast / banner when a `:break_glass_login` event arrives. The alert remains visible until acknowledged.

The structured log entry uses the `event` metadata field already defined in §2.7 so the JSON log line is filterable by `event = "auth.break_glass.login"` in any log aggregator.

#### 8.1.8.3 UI badge in user management

The user management LiveView annotates the break-glass row with a visible `BREAK-GLASS` badge and disables the row's delete / disable / change-auth-source affordances. The row cannot be hidden by a filter — administrators must always see that the account exists. Password rotation remains permitted (and is encouraged via documentation).

#### 8.1.8.4 EE local-auth disable (AUTH-106)

When an EE administrator sets `auth.local_auth_enabled = false`, two things happen:

1. The `SessionPlug` short-circuits local logins with a clear error before reaching the password check — including for the break-glass account. The row remains in the database but is unreachable through the auth path.
2. The setting change is itself recorded in the audit trail with a prominent action `auth.local_auth.disable`. The setting form requires the administrator to type an explicit confirmation phrase ("DISABLE BREAK-GLASS"), and a banner in the UI states the consequence: *the operator is now solely responsible for an out-of-band access path; if all IdPs fail and you have no host-level access, the platform is unreachable.*

CE has no such setting — `auth.local_auth_enabled` is hard-coded to `true` and the UI does not present a control to change it. This is the structural difference between the two editions for `AUTH-009` vs. `AUTH-106`.

#### 8.1.8.5 Seed-script behaviour

On first boot, the seed script:

1. Generates a random 24-character password for the break-glass admin.
2. Prints the password *once* to STDOUT with a banner saying it will not be shown again.
3. Stores the bcrypt/Argon2 hash in `users.password_hash`.
4. Records an audit entry `auth.break_glass.created` with the user_id and the source ("seed-script").

Operators are expected to rotate this password to one stored in their own secret manager before going live. A `mix vigil.rotate_break_glass_password` task is provided so the rotation does not require web-UI access.

## 8.2 Session management

```elixir
defmodule VigilWeb.SessionPlug do
  def call(conn, _) do
    with token when is_binary(token) <- get_session(conn, :token),
         {:ok, session, user} <- Accounts.fetch_session(token),
         :ok <- validate_lifetime(session) do
      maybe_touch_session(session)
      conn
      |> assign(:current_user, user)
      |> assign(:current_session, session)
    else
      _ -> conn
    end
  end

  # AUTH-010: debounce writes to sessions.last_active_at. The sessions table is
  # on the hot path for every authenticated request; unbounded writes create a
  # write hotspot that contends with rate-limiter lookups on the same table.
  defp maybe_touch_session(%Session{last_active_at: ts} = session) do
    debounce_ms = Application.get_env(:vigil, :session_touch_debounce_ms, 5 * 60 * 1_000)

    if System.monotonic_time(:millisecond) - to_monotonic(ts) >= debounce_ms do
      Accounts.touch_session!(session)   # persists a new last_active_at
    else
      :noop                              # within debounce window; no DB write
    end
  end
end
```

`validate_lifetime/1` checks absolute and idle expiries against the *debounced* `last_active_at`. The debounce window is short enough (default 5 minutes, configurable) that idle-timeout enforcement remains accurate within one window — a session that is genuinely idle for `idle_timeout + debounce_ms` is invalidated. The short staleness on `last_active_at` is an acceptable tradeoff for eliminating the write hotspot (`AUTH-010`, `NFR-007`).

For very short idle timeouts (< debounce window) — rare in practice but admin-configurable — the debounce window is automatically lowered to `idle_timeout / 4` by `Accounts.effective_debounce_ms/1` so enforcement accuracy is preserved.

Cross-tab logout (`UI-1401`, `STR-1003`) uses `Phoenix.PubSub.broadcast(Vigil.PubSub, "user_session:#{user_id}", {:logout})`. LiveView processes subscribed to this topic handle the message and redirect. Non-LiveView tabs detect expiry on next navigation.

## 8.3 Permission model

### 8.3.1 Permission identifier

Permissions are strings of the form:

```
<plugin_id>:<capability_or_resource>:<action>
```

Examples:

- `puppet:inventory:read`
- `bolt:command:execute`
- `aws:ec2:launch`
- `ansible:playbook:execute`
- `journal:note:create`
- `integration:configure`
- `rbac:role:update`
- `mcp:tool:invoke`

Cross-cutting permissions that aren't plugin-scoped use pseudo-plugins like `journal`, `integration`, `rbac`, `mcp`, `platform`.

### 8.3.2 Permission structure

A role's permission grant is a row in `role_permissions`:

```
action          = "bolt:task:execute"
integration_id  = <uuid or NULL for "all integrations of this plugin">
target_selector = %{groups: ["production"], tags: {"env": "prod"}}
command_policy  = %{
                    allow: ["package::install", "service::restart"],
                    deny:  ["package::remove"]
                  }
```

This structure supports:

- `RBAC-101` — scoping: action-level, integration-level, specific-action-level
- `RBAC-102`, `RBAC-103`, `RBAC-104` — per-command, per-task, per-playbook policies via `command_policy`
- `RBAC-105` — provisioning action per-node/group via `target_selector`
- `RBAC-107` — per-target scoping via `target_selector`

### 8.3.3 Permission evaluation

The evaluator assembles a user's effective permissions by union across roles:

```elixir
defmodule Vigil.Core.RBAC.Evaluator do
  def check(principal, action, context) do
    principal
    |> effective_permissions(action)
    |> Enum.any?(&permits?(&1, context))
    |> case do
      true -> :ok
      false -> {:error, :denied}
    end
  end

  defp effective_permissions(principal, action) do
    roles = Vigil.Core.RBAC.roles_for(principal)

    from(rp in RolePermission,
      where: rp.role_id in ^Enum.map(roles, & &1.id),
      where: rp.action == ^action or ^matches_wildcard(action)
    )
    |> Repo.all()
  end

  defp permits?(permission, context) do
    integration_matches?(permission, context.integration_id) and
    target_matches?(permission, context.resolved_targets) and
    command_matches?(permission, context.artifact)
  end
end
```

`context` carries the action's concrete target information. Critically, the evaluator **never** calls the database per target. The submission pipeline (`Vigil.Core.Executions.submit/2`) resolves targets once — using a single `Nodes.get_many/1` call that issues `WHERE id = ANY($1)` — and passes the pre-loaded node structs to the evaluator:

```elixir
# In Vigil.Core.Executions.Validator:
def validate(principal, submission) do
  resolved = %Context{
    integration_id: submission.integration_id,
    resolved_targets: Nodes.get_many(submission.target_node_ids, preload: [:sources]),
    artifact: submission.artifact
  }

  with :ok <- RBAC.check(principal, action_for(submission), resolved),
       :ok <- reachability(resolved) do
    {:ok, resolved}
  end
end
```

This satisfies `RBAC-108`: target-scope evaluation across N targets issues a constant number of queries regardless of N. `TEST-202a` explicitly asserts the query count at N = 1, 10, 100, 1000.

#### `target_matches?`

The target selector JSONB is interpreted as a filter against the already-loaded node list:

```elixir
defp target_matches?(%{target_selector: nil}, _), do: true
defp target_matches?(%{target_selector: sel}, nodes) when is_list(nodes) do
  Enum.all?(nodes, &node_in_selector?(&1, sel))
end

defp node_in_selector?(node, %{"tags" => tag_filter}) do
  tags = merged_tags(node)   # from preloaded node.sources
  Enum.all?(tag_filter, fn {k, vs} -> Map.get(tags, k) in vs end)
end
```

A permission with `target_selector: %{tags: {"env": ["dev", "staging"]}}` only permits actions against nodes tagged `env=dev` or `env=staging`. The per-node check is pure function logic over the preloaded struct — zero database round-trips.

For scheduled executions (EE FS EE-5), the resolved-targets fetch happens at *run time* so the RBAC check reflects current group memberships, tags, and target existence (`RBAC-108`, `FUT-106`). Scheduled jobs call `Validator.validate/2` with the schedule's owner principal and a fresh `Nodes.get_many/1` at trigger time.

> **Decision: Resolve targets once in the submission pipeline, never in the evaluator.**
> An earlier design called `Nodes.get/1` per target inside `target_matches?`. At 1000 targets this produced 1000 serial DB queries before the execution could even start — user-visible latency at scale and an interface-level defect that would be expensive to retrofit once the execution pipeline was built around it. Resolving once in the submission pipeline is the correct interface boundary: the evaluator is a pure function of `(permission, context)`.

#### `command_matches?` — glob allowlist / blocklist (EXEC-302 / EXEC-305)

For execution artifacts, the command policy uses **glob syntax only** — regex is explicitly out of scope per `EXEC-302`. The grammar matches what operators have already learned from shell globbing:

| Pattern element | Matches |
|-----------------|---------|
| literal text | exactly that text |
| `?` | exactly one character within a single argument token |
| `*` | any sequence of characters within a single argument token (does not cross whitespace boundaries) |
| `**` | any sequence of characters across argument boundaries (can span multiple tokens) |

Examples (from `EXEC-302`):

- `systemctl restart *` permits `systemctl restart nginx`, `systemctl restart postgres`, but **not** `systemctl restart "nginx postgres"` as a single quoted argument (the `*` stops at whitespace).
- `systemctl * nginx` permits `systemctl start nginx`, `systemctl restart nginx`, etc.
- `systemctl ** nginx` would additionally permit `systemctl --user start nginx` (the `**` spans the flag and the subcommand).

The compiler translates each pattern to a regex *once* at policy creation and stores the compiled pattern alongside the source. The hot-path matcher does a regex match, not a fresh glob parse:

```elixir
defmodule Vigil.Core.RBAC.GlobPolicy do
  @doc """
  Compiles a glob pattern to a regex. Called at policy write time, never on the hot path.
  Rejects regex metacharacters in the source so operators don't accidentally pass a regex
  expecting glob semantics.
  """
  def compile!(pattern) when is_binary(pattern) do
    if contains_regex_metachars?(pattern),
      do: raise(ArgumentError, "Allowlist patterns must use glob syntax, not regex. " <>
                                "Offending pattern: #{inspect(pattern)}")

    pattern
    |> escape_regex_metachars()
    |> translate_glob_to_regex()    # ? → ., * → [^[:space:]]*, ** → .*
    |> then(&("^" <> &1 <> "$"))
    |> Regex.compile!()
  end
end
```

The policy itself is two compiled lists per `role_permissions.command_policy`:

```elixir
%{
  "allow" => [compiled_regex, ...],     # empty list => open (all commands permitted)
  "deny"  => [compiled_regex, ...]
}
```

The matcher applies `EXEC-302` "empty allowlist = open, non-empty = closed" and `EXEC-305` "block matches terminate" semantics in this order:

```elixir
defp command_matches?(%{command_policy: nil}, _), do: true
defp command_matches?(%{command_policy: %{"allow" => allow, "deny" => deny}}, %{artifact: a}) do
  command_string = render_command(a)   # canonical "argv0 arg1 arg2 ..." form

  cond do
    # 1. Block patterns terminate first. A block match denies, full stop (EXEC-305).
    Enum.any?(deny, &Regex.match?(&1, command_string)) ->
      false

    # 2. Empty allowlist = open. Any non-blocked command is permitted (EXEC-302).
    allow == [] ->
      true

    # 3. Non-empty allowlist = closed. Command must match at least one allow pattern.
    true ->
      Enum.any?(allow, &Regex.match?(&1, command_string))
  end
end
```

Order matters and is `EXEC-305`-mandated: block patterns are evaluated *after* the conceptual allowlist gate, but a block match terminates the evaluation chain with rejection. A command that matches both an allowlist entry and a block pattern is **denied** — block wins.

#### Multi-role union (EXEC-303)

A user with multiple roles receives the **union** of all matching allowlists across those roles. Concretely: when compiling the principal's effective permissions, the dispatcher merges every role's `command_policy.allow` list into a single flat list, and likewise for `command_policy.deny`. The union is computed once per principal and cached in the `PermissionCache` (see [§8.3.4](#834-compiled-permission-cache)).

This matters for the open-vs-closed semantics: if any one of the user's roles has an empty allowlist for the integration, the union allowlist is empty *and the policy is "open"* — the broader role's grant subsumes the narrower role's restrictions. Operators who need closed-by-default semantics must ensure every role granting access to the integration carries a non-empty allowlist.

Block patterns (`EXEC-305`) are unioned the same way and always apply — a block pattern in any role's policy applies to that user regardless of which role granted the underlying allow.

### 8.3.4 Compiled permission cache

Permission evaluation runs in the dispatcher's hot path. To keep it fast, we compile a principal's effective permission set on session start and cache it in ETS:

```elixir
defmodule Vigil.Core.RBAC.PermissionCache do
  @table :rbac_permissions_cache

  def for_principal(principal_id) do
    case :ets.lookup(@table, principal_id) do
      [{^principal_id, compiled, valid_until}] when valid_until > now() ->
        compiled
      _ ->
        compiled = compile(principal_id)
        :ets.insert(@table, {principal_id, compiled, now() + 60_000})
        compiled
    end
  end

  def invalidate(principal_id), do: :ets.delete(@table, principal_id)
end
```

The cache is invalidated on:

- Role changes (update, delete)
- User role assignment changes
- IdP group re-evaluation (login)

Cache TTL is short (1 minute) as a backstop; primary correctness comes from active invalidation.

### 8.3.5 Plug / check sites

Permission checks are enforced:

- In Phoenix controllers via a plug that reads the route's declared permission.
- In LiveView `on_mount` callbacks.
- In the plugin dispatcher (pre-call).
- In context function bodies for defence-in-depth.
- In the MCP tool invocation layer.

Client-side hiding (not showing a button the user can't use) is convenience; server-side enforcement is security (`NFR-302`).

```elixir
defmodule VigilWeb.RBACPlug do
  def init(opts), do: opts

  def call(conn, permission: action) do
    context = context_from_params(conn)
    case RBAC.check(conn.assigns.current_user, action, context) do
      :ok -> conn
      {:error, :denied} -> conn |> put_status(:forbidden) |> render_denied()
    end
  end
end
```

### 8.3.6 Error messaging (`ERR-305`, `ERR-306`)

Denial messages distinguish:

- **Authentication failure:** "Your session has expired. Please log in again."
- **Authorization failure:** "Your role does not include permission to <action>. Required: `<permission>`. Contact your administrator."
- **Target scope failure:** "Your role does not permit this action on the selected targets."
- **Command policy failure:** "The command `<x>` is not on your allowlist."

No revelation of the resource's existence when the user lacks read on it — a node they can't see returns 404, not 403, to prevent existence enumeration (`ERR-306`).

## 8.4 Default roles

`RBAC-004` specifies built-in roles. We ship:

| Role | Permissions |
|------|-------------|
| `administrator` | All permissions. Seeded with `built_in = true`. |
| `operator` | Read on all capabilities; execute on allowed integrations; provisioning excluding destruction |
| `read-only` | Read-only on everything |
| `auditor` | Read-only on journal, audit trail, integration health. No operational surface. |
| `mcp-service` | Read-only MCP tools. Designed for AI service accounts. |

These are starting points; admins can modify permissions (`RBAC-004`). The `built_in` flag prevents deletion but not permission editing.

## 8.5 Group-to-role mapping (`RBAC-201..206`)

CE provides literal exact-match mapping for the OIDC provider. EE extends with wildcard patterns (`RBAC-204`) and re-evaluation on every login (`RBAC-205`).

UI in the settings panel (CE):

```
IdP        | Group (literal)     | Maps to Role
-----------+---------------------+----------------
OIDC       | vigil-admins        | administrator
OIDC       | vigil-ops           | operator
OIDC       | all-staff           | read-only
```

UI in the settings panel (EE — adds wildcard column and multi-IdP support):

```
IdP       | Group Pattern       | Maps to Role
----------+---------------------+----------------
Okta SAML | vigil-admins        | administrator
Okta SAML | vigil-ops           | operator
Azure AD  | sre-*               | operator
Okta SAML | *                   | read-only (catch-all)
```

Evaluation order is by specificity (exact match before wildcard, in EE). Multiple matches are additive — all matching roles are assigned.

CE enforces the literal constraint at the Ecto changeset level on `group_role_mappings.group_pattern`:

```elixir
def changeset(mapping, attrs) do
  mapping
  |> cast(attrs, [:idp, :group_pattern, :role_id])
  |> validate_required([:idp, :group_pattern, :role_id])
  |> validate_ce_literal_pattern()
end

defp validate_ce_literal_pattern(changeset) do
  if Vigil.Edition.enterprise?() do
    changeset
  else
    pattern = get_field(changeset, :group_pattern) || ""
    if String.contains?(pattern, ["*", "?", "[", "]"]) do
      add_error(changeset, :group_pattern,
        "wildcard patterns require the Enterprise Edition")
    else
      changeset
    end
  end
end
```

`Vigil.Edition.enterprise?/0` returns true iff `vigil_enterprise` is loaded and a valid license is active. In EE, the constraint is skipped; in CE, attempting to save a wildcard pattern produces a validation error with a "requires EE" hint.

`RBAC-206` transparency: the UI shows, per user, each role assignment and its source ("direct" or "group_mapped: sre-prod"). Administrators can quickly diagnose why a user has particular access. This is the same UI in both editions.

## 8.6 Audit

Every authorization check that results in a denial, and every permission change, produces an audit entry. Denials are audited at an `info` severity (they're normal); repeated denials within a window flag a potential authorization probe.

```elixir
defmodule Vigil.Core.Audit do
  def write(principal, action, target, opts \\ []) do
    %AuditEntry{}
    |> AuditEntry.changeset(%{
      tenant_id: principal.tenant_id,
      actor_user_id: principal.id,
      actor_label: principal.username,
      action: action,
      target_kind: opts[:target_kind],
      target_id: to_string(opts[:target_id]),
      params: redact(opts[:params] || %{}),
      result: opts[:result] || :success,
      correlation_id: Logger.metadata()[:correlation_id]
    })
    |> Repo.insert!()
  end
end
```

`RBAC-301..304` are served by this writer. The `redact/1` pass ensures secret-valued fields are stripped before persist.

## 8.7 RBAC-test property suite

Per `TEST-202`, RBAC evaluation is property-tested:

```elixir
property "union of roles is commutative and idempotent" do
  check all roles <- list_of(role_gen(), min_length: 1, max_length: 5),
            action <- action_gen() do

    result_a = evaluate(roles, action)
    result_b = evaluate(Enum.shuffle(roles ++ roles), action)
    assert result_a == result_b
  end
end

property "explicit deny always beats allow" do
  check all base <- role_with_allow_gen(),
            deny <- role_with_matching_deny_gen(base),
            action <- matching_action_gen(base) do
    assert evaluate([base, deny], action) == {:error, :denied}
  end
end

property "wildcard patterns match correctly" do
  check all pattern <- wildcard_gen(), matching <- matching_strings_gen(pattern) do
    assert matches_wildcard?(pattern, matching)
  end
end
```

## 8.8 Secrets integration

Per `NFR-201`, credentials are encrypted at rest. Integration credentials go through `Vigil.Core.Secrets`. User passwords are Argon2-hashed (not encrypted, not reversible). Session tokens are stored hashed (SHA-256 — adequate because random 32-byte tokens have no guessable patterns).

## 8.9 Summary of enforcement surfaces

| Surface | Enforcement |
|---------|-------------|
| Phoenix routes (HTML) | `VigilWeb.RBACPlug` on the pipeline |
| LiveView events | `on_mount` hook in `VigilWeb.LiveAuth`, plus per-event `authorize/3` |
| Plugin dispatcher | `Vigil.Core.RBAC.Evaluator.check/3` before any plugin call |
| REST / MCP API | `VigilWeb.APIAuthPlug` + per-action check |
| Oban background jobs | jobs carry the initiating principal ID; re-evaluate at run time (`FUT-106`) |

Every surface calls the same `check/3`. No surface has its own permission model (`RBAC-005`, `NFR-301`).

---

[← Previous: Journal & Events](07-journal-and-events.md) | [Next: LiveView UI →](09-liveview-ui.md)

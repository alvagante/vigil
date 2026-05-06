# 8. Authentication & RBAC

This section realizes PRD `AUTH-*`, `RBAC-*`, `NFR-201..301..604`. It covers local authentication (Phase 1), external IdPs (Phase 2), session and token handling, and the permission evaluation engine that gates every user-facing action and MCP tool call.

## 8.1 Authentication strategy

Phoenix's `phx.gen.auth` generator gives us a solid starting point for local auth. We extend it with pluggable external providers.

### 8.1.1 Local authentication (Phase 1)

The generated auth layer provides:

- `/users/register`, `/users/log_in`, `/users/log_out`, `/users/reset_password` routes
- Argon2 password hashing
- Session-based auth via signed cookies
- Password reset via token+email

Extensions we add:

- **Rate limiting** (`NFR-202`) via `Hammer` or custom ETS-based limiter per username and per IP.
- **Account lockout** (`NFR-203`) after N failures within a window, tracked in the `users.status` column.
- **Session lifetime controls** (`NFR-204`) — configurable absolute and idle timeouts applied in the session plug.
- **Audit trail on auth events** — every login, logout, lockout, password change produces an `audit_entries` row.

### 8.1.2 API tokens (`AUTH-005`)

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

### 8.1.3 External authentication (Phase 2)

The external auth layer sits on `Ueberauth` — a widely adopted Elixir authentication umbrella that abstracts SAML, OIDC, OAuth2, and LDAP behind a uniform callback contract.

```elixir
# config/config.exs
config :ueberauth, Ueberauth,
  providers: [
    saml:  {Ueberauth.Strategy.SAML, [request_path: "/auth/saml/request", ...]},
    oidc:  {Ueberauth.Strategy.OIDC, [...]},
    ldap:  {Ueberauth.Strategy.LDAP, [...]}
  ]
```

For SAML 2.0 specifically, we use `Samly` (which integrates with Ueberauth) — it supports Azure AD, Okta, ADFS, Keycloak out of the box (`AUTH-101`). For OIDC, we use `openid_connect` or the Ueberauth OIDC strategy (`AUTH-102`). For LDAP, `Exldap` (`AUTH-103`).

The auth controller's callback:

```elixir
def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _) do
  with {:ok, user} <- upsert_external_user(auth),
       :ok <- reevaluate_roles(user, auth.extra.groups),
       {:ok, session} <- start_session(user) do
    conn |> put_session(:token, session.token) |> redirect(to: "/")
  end
end
```

**JIT provisioning** (`AUTH-105`, `DM-301`): `upsert_external_user/1` creates the user record on first successful login. The lookup is by `(tenant_id, auth_source, external_subject)` — a stable IdP-provided subject. Subsequent logins hit the existing user.

**Group re-evaluation** (`RBAC-205`): on every login, we refresh `user_roles` rows with `source = 'group_mapped:...'` based on the current IdP group memberships. Rows with `source = 'direct'` are preserved.

```elixir
defp reevaluate_roles(user, idp_groups) do
  Repo.transaction(fn ->
    # Clear previously group-mapped assignments
    from(ur in UserRole,
      where: ur.user_id == ^user.id and like(ur.source, "group_mapped:%")
    )
    |> Repo.delete_all()

    # Apply current mappings
    for group <- idp_groups,
        mapping <- matching_mappings(user.auth_source, group) do
      Repo.insert!(%UserRole{
        user_id: user.id,
        role_id: mapping.role_id,
        source: "group_mapped:#{group}"
      })
    end
  end)
end
```

Wildcard patterns (`RBAC-204`) are glob-to-regex — e.g., `vigil-*` matches `vigil-ops`, `vigil-sre`.

### 8.1.4 Default role for unmapped users (`RBAC-203`)

If a user's groups don't match any mapping, they either get the configured default role or, if set to "deny access," the login fails with a clear error: "your account has no role assignments — contact your administrator."

### 8.1.5 Coexistence of local and external auth

`AUTH-106`, `AUTH-107`, `AUTH-109` are satisfied by:

- Local users remain authenticatable via their password hash.
- External users have `password_hash = NULL` and cannot log in locally.
- Break-glass local access remains available even when the IdP is down.
- An admin can disable local auth entirely via a setting; the UI then shows only IdP login buttons.

Sessions for already-authenticated users continue to work when the IdP is unavailable (`AUTH-109`); only *new* logins via that IdP fail.

## 8.2 Session management

```elixir
defmodule VigilWeb.SessionPlug do
  def call(conn, _) do
    with token when is_binary(token) <- get_session(conn, :token),
         {:ok, session, user} <- Accounts.fetch_session(token),
         :ok <- validate_lifetime(session) do
      touch_session(session)
      conn
      |> assign(:current_user, user)
      |> assign(:current_session, session)
    else
      _ -> conn
    end
  end
end
```

`validate_lifetime/1` checks absolute and idle expiries. On expiry, the session is invalidated and the user redirected to login.

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
    target_matches?(permission, context.target) and
    command_matches?(permission, context.artifact)
  end
end
```

`context` carries the action's concrete target information: integration id, target nodes (with their tags/groups), and for executions, the artifact name and arguments.

#### `target_matches?`

The target selector JSONB is interpreted as a filter:

```elixir
defp target_matches?(%{target_selector: nil}, _), do: true
defp target_matches?(%{target_selector: sel}, %{node_ids: ids}) do
  Enum.all?(ids, &node_in_selector?(&1, sel))
end

defp node_in_selector?(node_id, %{"tags" => tag_filter}) do
  node = Nodes.get(node_id, preload: [:sources])
  tags = merged_tags(node)
  Enum.all?(tag_filter, fn {k, vs} -> Map.get(tags, k) in vs end)
end
```

A permission with `target_selector: %{tags: {"env": ["dev", "staging"]}}` only permits actions against nodes tagged `env=dev` or `env=staging`.

#### `command_matches?`

For execution artifacts, the command policy is a `MapSet` check with glob/regex matching:

```elixir
defp command_matches?(%{command_policy: nil}, _), do: true
defp command_matches?(%{command_policy: %{"allow" => allow, "deny" => deny}}, %{artifact: a}) do
  not Enum.any?(deny, &matches?(&1, a)) and Enum.any?(allow, &matches?(&1, a))
end
```

Denies take precedence over allows (`EXEC-305`).

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

UI in the settings panel:

```
IdP       | Group Pattern       | Maps to Role
----------+---------------------+----------------
Okta      | vigil-admins        | administrator
Okta      | vigil-ops           | operator
Azure AD  | sre-*               | operator
Okta      | *                   | read-only (catch-all)
```

Evaluation order is by specificity (exact match before wildcard). Multiple matches are additive — all matching roles are assigned.

`RBAC-206` transparency: the UI shows, per user, each role assignment and its source ("direct" or "group_mapped: sre-prod"). Administrators can quickly diagnose why a user has particular access.

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

# 4. Data Model

This section maps the PRD's conceptual entities (section 12) onto Ecto schemas and a PostgreSQL layout. It describes which data is persisted, which is derived and cached, and how source attribution, scoping, and retention are implemented.

## 4.1 Guiding principles

- **Persist what must survive restart; derive everything else.** Per `DM-1101`, inventory, facts, configuration, events, reports, and monitoring state are derived on demand from upstream and cached. Executions, manual notes, audit, users, roles, integration configuration — persisted.
- **Source attribution at the row level.** Every row that came from a plugin carries its source. `(plugin_id, integration_id)` is stamped on each; `DM-1001`, `DM-1002` apply.
- **JSONB for heterogeneous payloads.** Journal details, fact maps, report content — all vary by plugin. PostgreSQL JSONB with GIN indexes gives us flexibility and queryability.
- **Tenant-ready but single-tenant by default.** Every user-scoped table has a `tenant_id` column. A single default tenant exists in single-tenant deployments. Multi-tenant expansion does not require schema migration (`FUT-401`).
- **Ecto contexts guard writes.** No module outside `Vigil.Core` writes to the database. LiveViews, plugins, and API controllers route through contexts.

## 4.2 Ecto contexts

| Context | Responsibility |
|---------|---------------|
| `Vigil.Core.Accounts` | Users, sessions, tokens, local auth, external identities |
| `Vigil.Core.RBAC` | Roles, permissions, group-to-role mappings, assignments |
| `Vigil.Core.Inventory` | Integration configs; linked node identities; group links; manual linking overrides |
| `Vigil.Core.Nodes` | Canonical node records (`Node`), identity attributes, source attributions |
| `Vigil.Core.Journal` | Journal entries (executions + manual notes), note revisions, filters |
| `Vigil.Core.Executions` | Executions and per-target transcripts |
| `Vigil.Core.Provisioning` | Provisioning operations state, correlation to upstream tasks |
| `Vigil.Core.Audit` | Append-only audit trail |
| `Vigil.Core.Secrets` | Encrypted credential store |
| `Vigil.Core.Settings` | Platform settings, retention policies, linking rules |

Contexts are the boundary: LiveViews and controllers call `Vigil.Core.Inventory.list_nodes/2`, not `Repo.all/1`. This lets us evolve storage (partition tables, add caches) without touching UI.

## 4.3 Core schemas

### 4.3.1 `nodes` — canonical node records

```sql
CREATE TABLE nodes (
  id                    UUID PRIMARY KEY,
  tenant_id             UUID NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
  canonical_name        TEXT NOT NULL,
  identity_attrs        JSONB NOT NULL,        -- {certname, fqdn, hostname, primary_ip, ...}
  first_seen_at         TIMESTAMPTZ NOT NULL,
  last_seen_at          TIMESTAMPTZ NOT NULL,
  lifecycle_state       TEXT NOT NULL DEFAULT 'active',
                                                -- 'active' | 'unreported' | 'decommissioned'
  unreported_since      TIMESTAMPTZ,           -- set when transitioning to :unreported
  decommissioned_at     TIMESTAMPTZ,           -- set when transitioning to :decommissioned
  decommissioned_by     UUID REFERENCES users(id),
  decommission_reason   TEXT,
  metadata              JSONB NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT nodes_canonical_unique UNIQUE (tenant_id, canonical_name),
  CONSTRAINT nodes_lifecycle_state_check
    CHECK (lifecycle_state IN ('active', 'unreported', 'decommissioned'))
);
CREATE INDEX nodes_identity_attrs_gin ON nodes USING GIN (identity_attrs);
CREATE INDEX nodes_last_seen_idx ON nodes (tenant_id, last_seen_at DESC);
CREATE INDEX nodes_lifecycle_idx ON nodes (tenant_id, lifecycle_state);
```

A `Node` row is the reconciled identity (`DM-001`). It is created on first observation and updated as identity attributes change. Canonical name is chosen per linking rules and persists unless manual override changes it.

The `lifecycle_state` column replaces the previous `deleted_at` soft-delete pattern, encoding the three-state model from `DM-1102`:

| State | Meaning | Trigger |
|-------|---------|---------|
| `active` | At least one integration currently reports this node. | Initial state on first observation. Restored from `unreported` when any integration re-reports the node. |
| `unreported` | No integration currently reports this node; it was previously active. Identity retained; derived data is stale or absent. | Set by `Vigil.Core.Inventory.Linker` when an integration cache refresh drops the last attribution (see [§5.2.5](05-aggregation-and-caching.md#525-detecting-the-unreported-transition-dm-1109)). |
| `decommissioned` | An administrator has explicitly tombstoned the node (`DM-1106`). | Explicit `Vigil.Core.Nodes.decommission/3` call. Releases identity claims in the linker index (`DM-1107`). Identity attrs preserved for historical Journal/Execution references. |

State transitions are authoritative writes through `Vigil.Core.Nodes.transition_lifecycle/2`, which:

1. Updates the row atomically.
2. Stamps the matching timestamp column (`unreported_since` or `decommissioned_at`).
3. Broadcasts `{:lifecycle, new_state, reason}` on the `node:lifecycle:<node_id>` PubSub topic so LiveViews repaint without polling.
4. For `:decommissioned`, additionally invokes `GenServer.call(Vigil.Core.Inventory.Linker, {:decommission, node_id, principal})` to release identity claims (`DM-1107` — see [§5.2.7](05-aggregation-and-caching.md#527-decommission-releases-identity-claims)).

The "Unreported nodes" administrator view (`DM-1109`) is a LiveView over `WHERE lifecycle_state = 'unreported' ORDER BY unreported_since DESC` joined with `node_sources` to show which integration last attributed each node and when. The view supports per-row "decommission" and "investigate" affordances.

> **Decision: Lifecycle state is a column, not a separate table or event log.**
> Each transition is recorded in the audit trail (`RBAC-301`) — that is the durable history. The column captures the *current* state, which is what every query needs. A separate `node_lifecycle_events` table was rejected: it would duplicate audit semantics, and "what state is this node in *now*" is the only question hot paths ask. The timestamp columns (`unreported_since`, `decommissioned_at`) give "how long has it been there" without a join.

### 4.3.2 `node_sources` — per-source observation

```sql
CREATE TABLE node_sources (
  id               UUID PRIMARY KEY,
  node_id          UUID NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  integration_id   UUID NOT NULL REFERENCES integrations(id) ON DELETE CASCADE,
  plugin_id        TEXT NOT NULL,
  source_identity  JSONB NOT NULL,   -- {certname: "x", fqdn: "y", ...} as the source reports them
  status           TEXT NOT NULL,    -- per-source status string
  groups           TEXT[] NOT NULL DEFAULT '{}',
  last_seen_at     TIMESTAMPTZ NOT NULL,
  metadata         JSONB NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT node_sources_unique UNIQUE (node_id, integration_id)
);
CREATE INDEX node_sources_integration_idx ON node_sources (integration_id);
```

One row per `(node_id, integration_id)` pair. This is the attribution layer (`DM-002`, `DM-1001`): when the aggregated inventory shows a node, it joins through here to show which integrations know about it, and at what identities they see it.

### 4.3.3 `manual_links` — admin override

```sql
CREATE TABLE manual_links (
  id               UUID PRIMARY KEY,
  tenant_id        UUID NOT NULL,
  action           TEXT NOT NULL CHECK (action IN ('link', 'unlink')),
  identity_a       JSONB NOT NULL,   -- %{plugin_id, integration_id, source_identity}
  identity_b       JSONB NOT NULL,
  created_by       UUID REFERENCES users(id),
  created_at       TIMESTAMPTZ NOT NULL,
  note             TEXT
);
```

Manual link/unlink decisions (`INV-106`, `INV-107`) persist here and are applied by the linker after automatic heuristics.

### 4.3.4 `groups` and `group_sources`

Analogous to nodes/node_sources. `groups` holds the canonical group identity; `group_sources` records each contributing integration's observation.

```sql
CREATE TABLE groups (
  id               UUID PRIMARY KEY,
  tenant_id        UUID NOT NULL,
  canonical_name   TEXT NOT NULL,
  metadata         JSONB NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT groups_canonical_unique UNIQUE (tenant_id, canonical_name)
);

CREATE TABLE group_sources (
  id               UUID PRIMARY KEY,
  group_id         UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  integration_id   UUID NOT NULL REFERENCES integrations(id) ON DELETE CASCADE,
  source_name      TEXT NOT NULL,     -- name as seen in the source
  hierarchy_parent TEXT,              -- preserved hierarchy (INV-304)
  metadata         JSONB NOT NULL DEFAULT '{}'::jsonb,
  UNIQUE (group_id, integration_id)
);
```

Group membership is not stored in a denormalized table (`DM-202`). It is computed via join:

```sql
SELECT DISTINCT n.id, n.canonical_name
FROM nodes n
JOIN node_sources ns ON ns.node_id = n.id
JOIN group_sources gs ON gs.source_name = ANY(ns.groups)
                      AND gs.integration_id = ns.integration_id
WHERE gs.group_id = $1
```

For performance at 10,000 nodes, this query is indexed on `(integration_id, source_name)` and `(node_id, integration_id)` — both covered by existing unique indexes. Membership computation is O(members), not O(all nodes).

### 4.3.5 `integrations` — configured integration instances

```sql
CREATE TABLE integrations (
  id               UUID PRIMARY KEY,
  tenant_id        UUID NOT NULL,
  plugin_id        TEXT NOT NULL,
  name             TEXT NOT NULL,
  config           JSONB NOT NULL,      -- secrets stored as refs
  enabled          BOOLEAN NOT NULL DEFAULT true,
  contract_version TEXT NOT NULL,
  health           JSONB NOT NULL DEFAULT '{}'::jsonb,   -- denormalized, last known
  created_at       TIMESTAMPTZ NOT NULL,
  updated_at       TIMESTAMPTZ NOT NULL,
  CONSTRAINT integrations_name_unique UNIQUE (tenant_id, name)
);
CREATE INDEX integrations_plugin_idx ON integrations (plugin_id);
```

The `health` column is a convenience mirror of the latest PubSub health update; it is not authoritative — the running plugin is. It exists so the initial page render does not have to wait for health probes to complete.

### 4.3.6 `integration_secrets` — encrypted credential storage

```sql
CREATE TABLE integration_secrets (
  id               UUID PRIMARY KEY,
  integration_id   UUID NOT NULL REFERENCES integrations(id) ON DELETE CASCADE,
  field_path       TEXT NOT NULL,   -- e.g., "puppetdb.client_cert"
  ciphertext       BYTEA NOT NULL,
  nonce            BYTEA NOT NULL,
  key_id           TEXT NOT NULL,   -- for future key rotation
  created_at       TIMESTAMPTZ NOT NULL,
  UNIQUE (integration_id, field_path)
);
```

AES-256-GCM. Key loaded from `VIGIL_SECRETS_KEY` at boot. Key rotation requires re-encrypting rows, which is an operator action.

## 4.4 Journal schemas

The journal table stores only Vigil-originated data: execution results and manual notes. External events (from PuppetDB, monitoring tools, cloud APIs, etc.) are fetched on-demand from the source tool and never stored locally. See [section 7](07-journal-and-events.md) for the full journal architecture.

```sql
CREATE TABLE journal_entries (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        UUID NOT NULL,
  node_id          UUID REFERENCES nodes(id) ON DELETE SET NULL,
  occurred_at      TIMESTAMPTZ NOT NULL,
  recorded_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  entry_type       TEXT NOT NULL,     -- 'execution' | 'manual_note'
  severity         TEXT NOT NULL DEFAULT 'informational',
  summary          TEXT NOT NULL,
  detail           JSONB NOT NULL DEFAULT '{}'::jsonb,
  -- Execution-specific
  execution_id     UUID REFERENCES executions(id) ON DELETE SET NULL,
  -- Manual note-specific
  author_user_id   UUID REFERENCES users(id) ON DELETE SET NULL,
  -- Metadata
  deleted_at       TIMESTAMPTZ       -- soft-delete for manual notes only
);
CREATE INDEX journal_node_time_idx ON journal_entries (node_id, occurred_at DESC);
CREATE INDEX journal_tenant_time_idx ON journal_entries (tenant_id, occurred_at DESC);
CREATE INDEX journal_entry_type_idx ON journal_entries (entry_type);
```

Notes on this design:

- **Minimal schema** — only stores what Vigil originates. No dedup index needed (no external ingestion).
- **Severity** supports filtering when merging with externally-fetched entries in the LiveView.
- **Soft-delete** only for manual notes the author removes (`DM-501`).
- **No full-text search index** — text search is handled client-side in the browser across all rendered entries (local + fetched).

### 4.4.1 Manual note edit history

```sql
CREATE TABLE journal_note_revisions (
  id               UUID PRIMARY KEY,
  journal_entry_id UUID NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
  editor_user_id   UUID REFERENCES users(id),
  previous_summary TEXT NOT NULL,
  previous_detail  JSONB NOT NULL,
  edited_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

`JRN-303` preserves audit of manual note edits.

## 4.5 Execution and transcript schemas

Per **ADR-0004**, the execution model is **one row per target node**, with all rows from the same dispatch sharing a stable `execution_group_id`. A 100-node dispatch creates 100 rows atomically; a single-node dispatch creates a group of one. Per **ADR-0005**, nodes denied by RBAC before dispatch produce **no row in `executions`** — the audit trail (`audit_entries`) is the sole authoritative record of denied nodes.

This inverts the more familiar "one job + many job-events" model. The rationale (per ADR-0004): every per-node consumer in the system — the journal entry (`DM-606`), the node detail page's execution history, RBAC target-scope evaluation — is now a 1:1 lookup, not an iteration over an embedded array.

### 4.5.1 `execution_groups` — dispatch metadata shared across targets

```sql
CREATE TABLE execution_groups (
  id                 UUID PRIMARY KEY,             -- the execution_group_id
  tenant_id          UUID NOT NULL,
  initiated_by       UUID NOT NULL REFERENCES users(id),
  integration_id     UUID NOT NULL REFERENCES integrations(id),
  plugin_id          TEXT NOT NULL,
  artifact_kind      TEXT NOT NULL,        -- 'command' | 'task' | 'playbook' | 'plan'
  artifact_name      TEXT,
  parameters         JSONB NOT NULL DEFAULT '{}'::jsonb,
  target_spec        JSONB NOT NULL,       -- what the user selected: nodes, groups, filter
  intended_targets   JSONB NOT NULL,       -- full original target list (incl. denied) for re-run
  dispatched_count   INTEGER NOT NULL,     -- count of executions rows actually created
  denied_count       INTEGER NOT NULL DEFAULT 0,  -- count of pre-dispatch denials (per ADR-0005)
  submitted_at       TIMESTAMPTZ NOT NULL,
  metadata           JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX execution_groups_user_idx       ON execution_groups (initiated_by, submitted_at DESC);
CREATE INDEX execution_groups_integration_idx ON execution_groups (integration_id, submitted_at DESC);
```

`execution_groups` carries the per-dispatch state that is identical across every targeted node: who submitted it, which integration, what was the original target intent, when it was submitted. It is the stable, URL-safe external reference for "I ran this action" (`DM-601a`). It does **not** carry per-target outcome or timing — those live on each `executions` row.

`intended_targets` preserves the full original target list (including nodes that were ultimately denied by RBAC). This is what `RBAC-109` requires the audit trail to record; storing it here as well lets "re-run group" reconstruct the original user intent without joining audit. `dispatched_count` and `denied_count` together always sum to `length(intended_targets)`, providing an O(1) source for the execution list view's per-group summary.

### 4.5.2 `executions` — one row per target node

```sql
CREATE TABLE executions (
  id                    UUID PRIMARY KEY,
  execution_group_id    UUID NOT NULL REFERENCES execution_groups(id) ON DELETE CASCADE,
  tenant_id             UUID NOT NULL,
  node_id               UUID REFERENCES nodes(id) ON DELETE SET NULL,
  target_identity       JSONB NOT NULL,        -- the integration-side identity that was dispatched
  outcome               TEXT NOT NULL DEFAULT 'running',
                                                -- 'running' | 'ok' | 'changed' | 'failed'
                                                -- | 'timed_out' | 'unreachable'
                                                -- | 'aborted' | 'aborted_by_restart'
                                                -- | 'failed_to_start'
  streaming_state       TEXT NOT NULL DEFAULT 'live',  -- 'live' | 'closed'
  exit_status           INTEGER,
  started_at            TIMESTAMPTZ NOT NULL,
  ended_at              TIMESTAMPTZ,
  duration_ms           INTEGER,
  transcript            BYTEA,                 -- gzipped stdout+stderr; capped at 50 MB
  transcript_meta       JSONB NOT NULL DEFAULT '{}'::jsonb,
                                                -- { stdout_bytes, stderr_bytes,
                                                --   truncated, truncated_at_bytes,
                                                --   last_checkpoint_at, restart_event_count }
  partial_transcript    BYTEA,                 -- gzipped checkpoint snapshot (EXEC-106)
  metadata              JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX executions_group_idx      ON executions (execution_group_id);
CREATE INDEX executions_node_idx       ON executions (node_id, started_at DESC);
CREATE INDEX executions_outcome_idx    ON executions (execution_group_id, outcome);
CREATE INDEX executions_running_idx    ON executions (streaming_state)
                                       WHERE streaming_state = 'live';
```

`DM-601` and `ADR-0005`: an `executions` row exists only for a node that was actually dispatched. **Denied nodes do not appear here at all** — they appear in `audit_entries.params.denied_targets` for the group's submission audit entry. This means a 100-node dispatch with 10 RBAC denials creates exactly 90 `executions` rows.

The `outcome` column is the per-target terminal state. `streaming_state` tracks whether the row is still receiving live output; the index over `WHERE streaming_state = 'live'` supports a fast "what's running right now" query without scanning completed rows.

`partial_transcript` holds gzipped checkpoint snapshots written during long executions (default every 30 s — see design/06 §6.2.8). On clean completion `transcript` is written and `partial_transcript` is cleared. On restart-induced abort, `partial_transcript` is promoted to `transcript` and `outcome` is set to `aborted_by_restart`. This is the mechanism that satisfies `EXEC-106`.

### 4.5.3 Transcript size cap and truncation (DM-604)

`DM-604` requires a configurable per-record cap (default 50 MB) with an explicit truncation marker. The Stream GenServer (design/06 §6.2.4) tracks bytes written per target. On crossing the cap:

1. Output continues to flow to subscribers (the user keeps seeing output in the UI), but new bytes are *not* appended to the buffer that will be persisted.
2. `transcript_meta.truncated` is set to `true` and `transcript_meta.truncated_at_bytes` records the cap.
3. A sentinel chunk `[--- transcript truncated at 50 MB; further output not persisted ---]` is appended to the buffer.
4. The runner is not killed — `DM-604` says truncation is not an error.

On completion, the gzipped persisted bytes will be smaller than 50 MB (gzip compresses well), but the cap is enforced on *uncompressed* size to keep the contract intuitive. The cap is overridable per integration via `executions.transcript_cap_bytes` in `settings`.

### 4.5.4 Aggregate group status (computed, not stored)

The group's aggregate "status" is a view over the `executions` rows for that group — derivable in a single indexed query (`executions_outcome_idx` above):

```sql
SELECT execution_group_id,
       COUNT(*) FILTER (WHERE outcome = 'ok')             AS ok_count,
       COUNT(*) FILTER (WHERE outcome = 'failed')          AS failed_count,
       COUNT(*) FILTER (WHERE outcome = 'unreachable')     AS unreachable_count,
       COUNT(*) FILTER (WHERE streaming_state = 'live')    AS still_running,
       COUNT(*)                                            AS dispatched
FROM executions
WHERE execution_group_id = $1
GROUP BY execution_group_id;
```

This drives the execution list view's per-group summary row required by `DM-605` (`47 ok / 2 failed / 1 unreachable`). It is *not* denormalized into `execution_groups` — recomputing is cheap (the group's row count is bounded by `intended_targets`), and a denormalized status would be a write coordinator between every Stream GenServer.

The "group is finished" boolean is `still_running = 0`. A LiveView watching a group subscribes to one PubSub topic per running `executions` row's `execution_stream:<id>`, and the LiveView's local aggregate updates when each row's `streaming_state` transitions to `closed`.

### 4.5.5 Streaming output into the transcript field

`EXEC-101` requires live streaming to the UI; `DM-604` requires the final transcript to be persisted. The two are decoupled:

- **During the run** the Stream GenServer holds the per-target buffer in memory (ring buffer, default 128 KB) and broadcasts each chunk on `execution_stream:<execution_id>`. The `executions.transcript` column is `NULL`.
- **Checkpoints** (every 30 s after the 60 s warm-up window) write the *cumulative* buffer to `partial_transcript` as a single gzipped blob. This is an `UPDATE` with `partial_transcript = $1` — no `bytea_append`, no row growth pathology.
- **Completion** writes the full buffer to `transcript` in one final `UPDATE` and clears `partial_transcript`. The Stream GenServer also updates `outcome`, `exit_status`, `ended_at`, `duration_ms`, and `streaming_state = 'closed'` in the same statement so the row reaches its terminal state atomically.

The Postgres `bytea` field is *not* used as an incremental append target. PostgreSQL TOAST handles large columns fine, but `UPDATE` on a bytea column writes the entire new value — checkpointing into the column is acceptable because checkpoints are every 30 s, not per-chunk. Per-chunk persistence would generate one row update per output line, which is the wrong write pattern.

### 4.5.6 Per-target journal entries (DM-606)

`DM-606` mandates exactly one Journal Entry per target node per execution. Because each `executions` row already is per-node, this is a 1:1 insert at completion. The journal write happens in the same `Repo.transaction/1` as the final `executions` update so the two cannot drift.

### 4.5.7 Why per-row scale is fine

Transcripts are gzipped `bytea`. A representative 100-node dispatch produces 100 rows; typical per-target transcripts are 1–10 KB (a `systemctl status` line) up to a few MB (a verbose Bolt task). PostgreSQL TOAST stores oversized values out-of-line transparently; index hot paths (`executions_group_idx`, `executions_node_idx`) touch only the small columns. At the 10,000-node target and a busy operator's 100 dispatches per day × 50 nodes mean, the table grows by ~5,000 rows/day — well inside what a single PostgreSQL instance handles unpartitioned for years.

Retention is per `DM-1103` via `settings.retention.executions_days` (default unbounded). The retention worker deletes finalized `executions` rows older than the retention window; `ON DELETE CASCADE` from `execution_groups` cleans the group row when its last `executions` row is deleted.

## 4.6 Users, roles, permissions

### 4.6.1 Users

```sql
CREATE TABLE users (
  id               UUID PRIMARY KEY,
  tenant_id        UUID NOT NULL,
  username         TEXT NOT NULL,
  email            TEXT,
  display_name     TEXT,
  password_hash    TEXT,                -- NULL for external users
  auth_source      TEXT NOT NULL,        -- 'local' | 'saml:<idp>' | 'oidc:<idp>' | 'ldap:<idp>'
  external_subject TEXT,                -- stable IdP-provided subject
  status           TEXT NOT NULL DEFAULT 'active',  -- 'active' | 'disabled' | 'locked'
  last_login_at    TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL,
  updated_at       TIMESTAMPTZ NOT NULL,
  CONSTRAINT users_username_unique UNIQUE (tenant_id, username),
  CONSTRAINT users_external_unique UNIQUE (tenant_id, auth_source, external_subject)
);
```

`password_hash` is NULL for externally authenticated users (`AUTH-054` for CE OIDC, `AUTH-104` for EE providers; `DM-302`). The unique constraints match local users, CE OIDC (`AUTH-051..057`), and EE external providers (`AUTH-101..110`) without overlap.

### 4.6.2 Sessions and tokens

```sql
CREATE TABLE sessions (
  id               UUID PRIMARY KEY,
  user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash       BYTEA NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL,
  last_active_at   TIMESTAMPTZ NOT NULL,
  absolute_expires_at TIMESTAMPTZ NOT NULL,
  idle_expires_at  TIMESTAMPTZ NOT NULL,
  client_meta      JSONB NOT NULL DEFAULT '{}'::jsonb   -- user-agent, ip, etc.
);

CREATE TABLE api_tokens (
  id               UUID PRIMARY KEY,
  user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name             TEXT NOT NULL,
  token_hash       BYTEA NOT NULL,
  scopes           TEXT[] NOT NULL DEFAULT '{}',
  created_at       TIMESTAMPTZ NOT NULL,
  last_used_at     TIMESTAMPTZ,
  expires_at       TIMESTAMPTZ,
  revoked_at       TIMESTAMPTZ
);
```

Token hashing: SHA-256 stored; plaintext shown once at creation. Lookup is O(1) via unique hash index.

### 4.6.3 Roles and permissions

```sql
CREATE TABLE roles (
  id               UUID PRIMARY KEY,
  tenant_id        UUID NOT NULL,
  name             TEXT NOT NULL,
  description      TEXT,
  built_in         BOOLEAN NOT NULL DEFAULT false,
  created_at       TIMESTAMPTZ NOT NULL,
  updated_at       TIMESTAMPTZ NOT NULL,
  CONSTRAINT roles_name_unique UNIQUE (tenant_id, name)
);

CREATE TABLE role_permissions (
  id               UUID PRIMARY KEY,
  role_id          UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  action           TEXT NOT NULL,       -- 'puppet:inventory:read', 'bolt:command:execute'
  integration_id   UUID REFERENCES integrations(id) ON DELETE CASCADE,  -- NULL = all
  target_selector  JSONB,               -- e.g., {tag: {env: ['dev']}}, or group filters
  command_policy   JSONB,               -- for execute: {allow: [...], deny: [...]}
  created_at       TIMESTAMPTZ NOT NULL
);
CREATE INDEX role_permissions_role_idx ON role_permissions (role_id);
CREATE INDEX role_permissions_action_idx ON role_permissions (action);

CREATE TABLE user_roles (
  user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id          UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  source           TEXT NOT NULL,        -- 'direct' | 'group_mapped:<group_name>'
  assigned_at      TIMESTAMPTZ NOT NULL,
  assigned_by      UUID REFERENCES users(id),
  PRIMARY KEY (user_id, role_id, source)
);

CREATE TABLE group_role_mappings (
  id               UUID PRIMARY KEY,
  tenant_id        UUID NOT NULL,
  idp              TEXT NOT NULL,        -- matches users.auth_source
  group_pattern    TEXT NOT NULL,        -- literal or wildcard (`vigil-*`)
  role_id          UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  created_at       TIMESTAMPTZ NOT NULL
);
```

This schema satisfies:

- `RBAC-002` additive roles via `user_roles` composite keys.
- `RBAC-101` three-scope permissions: `action` (integration-type level), `integration_id` (specific integration), `target_selector` / `command_policy` (specific action detail).
- `RBAC-201`..`RBAC-206` group-to-role mapping via `group_role_mappings` and `user_roles.source = 'group_mapped:<group>'`.
- `RBAC-107` per-target scoping via `target_selector` JSONB.

Permission evaluation is covered in [section 8](08-auth-rbac.md).

## 4.7 Audit trail

Append-only table. `NFR-602`: audit entries are never modified after finalisation.

```sql
CREATE TABLE audit_entries (
  id               UUID PRIMARY KEY,
  tenant_id        UUID NOT NULL,
  occurred_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  actor_user_id    UUID REFERENCES users(id),
  actor_label      TEXT,               -- fallback when user is deleted
  action           TEXT NOT NULL,       -- 'auth.login', 'rbac.role.update', 'execution.submit', ...
  target_kind      TEXT,               -- 'node', 'integration', 'role', 'user', ...
  target_id        TEXT,
  params           JSONB NOT NULL DEFAULT '{}'::jsonb,  -- with secrets redacted
  result           TEXT NOT NULL,       -- 'pending' | 'success' | 'denied' | 'failure' | 'error'
  correlation_id   TEXT,
  request_meta     JSONB NOT NULL DEFAULT '{}'::jsonb,  -- ip, user-agent
  finalized_at     TIMESTAMPTZ          -- NULL iff result = 'pending'
);
CREATE INDEX audit_actor_idx ON audit_entries (tenant_id, actor_user_id, occurred_at DESC);
CREATE INDEX audit_target_idx ON audit_entries (tenant_id, target_kind, target_id, occurred_at DESC);
CREATE INDEX audit_action_idx ON audit_entries (tenant_id, action, occurred_at DESC);
CREATE INDEX audit_pending_idx ON audit_entries (result, occurred_at) WHERE result = 'pending';
```

The `result` column has a `pending` state for the audit-first ordering pattern (`RBAC-305`): the entry is inserted in the same DB transaction as the action's source-of-truth row (e.g., the `executions` row), then transitioned to `success` or `failure` once the action's side effect has been initiated. `finalized_at` is NULL while pending and is set at transition. The partial index on `result = 'pending'` supports the reconciliation job (design/06 §6.2.2) that sweeps orphaned pending entries.

`RBAC-304` forbids ordinary deletion. The retention policy runs as an admin-authorized scheduled job — not a regular delete path. Export (`RBAC-303`) is a read-only stream generated by a background job into a downloadable object.

Finalised audit entries (`result != 'pending'`) are effectively immutable: updates are rejected at the Ecto changeset level and — as a defence in depth — by a Postgres trigger that raises on any UPDATE of columns other than `result`, `finalized_at`, and `params.reason` when the prior `result` was `pending`.

## 4.8 Linking rules and settings

```sql
CREATE TABLE linking_rules (
  id               UUID PRIMARY KEY,
  tenant_id        UUID NOT NULL,
  rule             JSONB NOT NULL,     -- e.g., {match: 'certname', fallback: ['fqdn', 'hostname']}
  priority         INTEGER NOT NULL,
  enabled          BOOLEAN NOT NULL DEFAULT true,
  created_at       TIMESTAMPTZ NOT NULL,
  updated_at       TIMESTAMPTZ NOT NULL
);

CREATE TABLE settings (
  tenant_id        UUID PRIMARY KEY,
  key              TEXT,
  value            JSONB NOT NULL,
  updated_by       UUID REFERENCES users(id),
  updated_at       TIMESTAMPTZ NOT NULL
);
```

Settings includes retention (per executions / audit), default timezone, branding, AI provider config (with secrets refs), etc.

## 4.9 Derived data: where it lives

Per `DM-1101`, inventory, facts, configuration, events, monitoring state, reports, and deployment history are all derived — fetched on-demand from the source tool and cached short-term in ETS. They are never persisted in PostgreSQL.

| Data | Runtime location | Not persisted because |
|------|------------------|----------------------|
| Node inventory list | ETS cache, keyed per integration | Always reconstructible from the source |
| Facts per node | ETS cache, keyed `{integration_id, node_id}` | Same |
| Hiera / catalog / config | ETS cache + local control-repo on disk | Same; repo is source of truth |
| Events (journal from external sources) | Fetched on-demand, briefly cached in ETS (30-60s) | Source tool is authoritative; no local duplication |
| Reports | Fetched on-demand from source API | Source tool is authoritative |
| Monitoring state | Very short-lived ETS cache (seconds) | Real-time; would be stale anywhere else |
| Deployment history | Fetched on-demand from source API | Source tool is authoritative |

Only Vigil-originated data is persisted: executions, manual notes, audit trail, users/roles, integration config, linking decisions.

## 4.10 Migrations and tooling

- **Migrations** via `ecto_migrate`. Versioned, reversible where practical.
- **Seeding** via `priv/repo/seeds.exs` — creates the default tenant, the built-in roles, and optionally a development admin user.
- **Data generator** for testing (`TEST-902`) lives under `apps/vigil_core/lib/vigil/core/test_data.ex`. It can generate synthetic inventories at target scale.

Schema changes to the plugin contract are handled by the contract-version compatibility layer (`PLUG-602`), not by database migrations.

## 4.11 Tenant scoping enforcement

Every user-scoped table carries a `tenant_id` column (`FUT-401`). In single-tenant CE deployments, all rows share `tenant_id = '00000000-...'` and tenant concerns are transparent. In EE multi-tenancy (FS EE-8), queries that forget to filter on `tenant_id` leak data between tenants silently — no crash, no error, wrong data returned.

Relying on developer discipline is inadequate for a data-isolation guarantee. We enforce tenant scoping at two levels, in depth.

### 4.11.1 Context-layer enforcement (CE and EE)

Every Ecto context module that exposes a query function takes a `Vigil.Core.Scope` struct as its first argument. The scope carries the current principal and tenant_id. A module attribute enforces the convention at compile time:

```elixir
defmodule Vigil.Core.Inventory do
  use Vigil.Core.Context.Scoped

  def list_nodes(%Scope{} = scope, filter \\ %{}) do
    Node
    |> scope_by(scope)         # injects WHERE tenant_id = scope.tenant_id
    |> apply_filter(filter)
    |> Repo.all()
  end

  def get_node!(%Scope{} = scope, id) do
    Node
    |> scope_by(scope)
    |> Repo.get!(id)
  end
end
```

`Vigil.Core.Context.Scoped` is a small `use` macro that:

- Exposes a `scope_by/2` helper that injects `where: [tenant_id: ^scope.tenant_id]` into an Ecto query.
- Requires the first argument of every public function to be `Scope`-typed (enforced by a Credo check).
- Provides a `raw_query/1` escape hatch for the rare cross-tenant administrative query — this is explicitly audited in code review.

All LiveView and controller boundaries construct a `Scope` from the authenticated session before calling into contexts. There is no path to a context function without a scope.

### 4.11.2 Query-plan enforcement via a test harness

A test-only Ecto telemetry handler inspects every SQL query fired during the test suite and, for any tenant-scoped table, asserts that the query's `WHERE` clause constrains `tenant_id`. A violation fails the test with a clear message:

```elixir
defmodule Vigil.Test.TenantScopeCheck do
  @tenant_scoped_tables ~w(nodes node_sources groups group_sources journal_entries
                           execution_groups executions audit_entries integrations
                           users sessions api_tokens roles)

  def attach do
    :telemetry.attach("tenant-scope-check", [:vigil, :repo, :query], &handle/4, nil)
  end

  defp handle(_event, _measurements, %{source: source, query: sql}, _config)
       when source in @tenant_scoped_tables do
    unless String.contains?(sql, "tenant_id") or bypass_allowed?(sql) do
      raise "Tenant-scope violation: query against #{source} without tenant_id filter:\n#{sql}"
    end
  end
end
```

This catches every code path a test exercises, before the code reaches production. For production, the context-layer convention plus this test-time safety net is considered adequate for CE's single-tenant reality and EE's expected deployment patterns.

### 4.11.3 Future escalation (EE SaaS)

If Vigil ever becomes a project-operated multi-tenant SaaS (explicitly out of scope per PRD §21.6), the expected escalation is Postgres Row-Level Security (RLS): each tenant-scoped table gets an RLS policy keyed on a session variable `app.current_tenant_id`, set by the application at transaction start. RLS becomes the primary defence; the context macro becomes a convenience layer. This path is preserved by the current design — no schema changes are needed to enable it, only policy definitions and a session-variable plug.

## 4.12 Query patterns and scale

At 10,000 nodes:

- `nodes` table: 10,000 rows. Trivial.
- `node_sources`: up to 10,000 × (number of integrations per node) ≈ 30,000 rows. Trivial.
- `journal_entries`: low volume — only executions and manual notes. Hundreds per day in a busy deployment. No partitioning needed.
- `execution_groups` + `executions`: low volume. Hundreds of dispatches per day in typical deployments, fanning out to ~50× as many `executions` rows under the per-node model (`ADR-0004`).
- `audit_entries`: bounded by user activity. Low volume, retained longer.

The database is small by design. All high-volume data (events, reports, facts, inventory) lives in the source tools and is fetched on-demand. PostgreSQL stores only what Vigil originates or must persist for accountability.

First-page render at 10,000 nodes (`NFR-002`):

- Per-source inventory lists come from ETS cache in microseconds.
- Merging and rendering through LiveView add milliseconds.
- The bottleneck is network / external tool latency on cold cache.

Cached hits comfortably meet the 2-second target. Cold cache fallback meets the same target when the primary source is healthy (PuppetDB PQL is capable of returning 10,000 certnames with status in under a second). See [section 5](05-aggregation-and-caching.md).

---

[← Previous: Plugin Framework](03-plugin-framework.md) | [Next: Aggregation & Caching →](05-aggregation-and-caching.md)

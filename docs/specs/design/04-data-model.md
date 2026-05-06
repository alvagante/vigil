# 4. Data Model

This section maps the PRD's conceptual entities (section 12) onto Ecto schemas and a PostgreSQL layout. It describes which data is persisted, which is derived and cached, and how source attribution, scoping, and retention are implemented.

## 4.1 Guiding principles

- **Persist what must survive restart; derive everything else.** Per `DM-1101`, inventory, facts, and configuration are derived on demand from upstream and cached. Journal entries, executions, audit, users, roles, configuration — persisted.
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
| `Vigil.Core.Journal` | Journal entries, manual notes, event grouping, filters, retention |
| `Vigil.Core.Executions` | Executions and per-target transcripts |
| `Vigil.Core.Reports` | Persisted reports, summary metrics, phase timings |
| `Vigil.Core.Provisioning` | Provisioning operations state, correlation to upstream tasks |
| `Vigil.Core.Audit` | Append-only audit trail |
| `Vigil.Core.Secrets` | Encrypted credential store |
| `Vigil.Core.Settings` | Platform settings, retention policies, linking rules |

Contexts are the boundary: LiveViews and controllers call `Vigil.Core.Inventory.list_nodes/2`, not `Repo.all/1`. This lets us evolve storage (partition tables, add caches) without touching UI.

## 4.3 Core schemas

### 4.3.1 `nodes` — canonical node records

```sql
CREATE TABLE nodes (
  id               UUID PRIMARY KEY,
  tenant_id        UUID NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
  canonical_name   TEXT NOT NULL,
  identity_attrs   JSONB NOT NULL,        -- {certname, fqdn, hostname, primary_ip, ...}
  first_seen_at    TIMESTAMPTZ NOT NULL,
  last_seen_at     TIMESTAMPTZ NOT NULL,
  deleted_at       TIMESTAMPTZ,           -- soft-delete when no source reports it
  metadata         JSONB NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT nodes_canonical_unique UNIQUE (tenant_id, canonical_name)
);
CREATE INDEX nodes_identity_attrs_gin ON nodes USING GIN (identity_attrs);
CREATE INDEX nodes_last_seen_idx ON nodes (tenant_id, last_seen_at DESC);
```

A `Node` row is the reconciled identity (`DM-001`). It is created on first observation and updated as identity attributes change. Canonical name is chosen per linking rules and persists unless manual override changes it.

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

The journal is the most write-heavy and the most queried non-derived data in the system. It's designed for growth.

```sql
CREATE TABLE journal_entries (
  id               UUID PRIMARY KEY,
  tenant_id        UUID NOT NULL,
  node_id          UUID REFERENCES nodes(id) ON DELETE SET NULL,
  occurred_at      TIMESTAMPTZ NOT NULL,
  recorded_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  integration_id   UUID REFERENCES integrations(id) ON DELETE SET NULL,
  plugin_id        TEXT,
  entry_type       TEXT NOT NULL,     -- 'event', 'execution', 'provisioning',
                                      -- 'deployment', 'monitoring_transition',
                                      -- 'configuration_change', 'manual_note'
  severity         TEXT NOT NULL DEFAULT 'info',  -- 'info' | 'notice' | 'warning' | 'error'
  summary          TEXT NOT NULL,
  detail           JSONB NOT NULL DEFAULT '{}'::jsonb,
  group_key        TEXT,              -- per-source grouping (Puppet report ID)
  source_event_id  TEXT,              -- upstream ID for idempotency
  search_text      TSVECTOR GENERATED ALWAYS AS (
                     to_tsvector('english', summary || ' ' || coalesce(detail::text, ''))
                   ) STORED,
  references       JSONB NOT NULL DEFAULT '{}'::jsonb,  -- {report_id, execution_id, ...}
  author_user_id   UUID REFERENCES users(id) ON DELETE SET NULL, -- manual notes only
  deleted_at       TIMESTAMPTZ
);
CREATE INDEX journal_node_time_idx ON journal_entries (node_id, occurred_at DESC);
CREATE INDEX journal_tenant_time_idx ON journal_entries (tenant_id, occurred_at DESC);
CREATE INDEX journal_group_key_idx ON journal_entries (group_key) WHERE group_key IS NOT NULL;
CREATE INDEX journal_search_gin ON journal_entries USING GIN (search_text);
CREATE INDEX journal_detail_gin ON journal_entries USING GIN (detail);
CREATE UNIQUE INDEX journal_dedupe_idx
  ON journal_entries (integration_id, source_event_id)
  WHERE source_event_id IS NOT NULL;
```

Notes on this design:

- **Idempotent re-ingest** via the unique `(integration_id, source_event_id)` index (`JRN-204`). When a plugin re-fetches events, duplicates are silently skipped.
- **Group key** preserves source grouping (`JRN-005`, `DM-503`) — all events from one Puppet report share the report's ID.
- **Full-text search** over summary + detail via a stored tsvector (`UI-403`, `JRN-103`).
- **Severity** supports the filter requirement.
- **Soft-delete** only for manual notes the author removes (`DM-501`); system entries never delete until retention.

Partitioning by month is planned if entry volume warrants it; the schema is partition-ready via `occurred_at` as the partition key.

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

```sql
CREATE TABLE executions (
  id               UUID PRIMARY KEY,
  tenant_id        UUID NOT NULL,
  initiated_by     UUID NOT NULL REFERENCES users(id),
  integration_id   UUID NOT NULL REFERENCES integrations(id),
  plugin_id        TEXT NOT NULL,
  artifact_kind    TEXT NOT NULL,     -- 'command' | 'task' | 'playbook' | 'plan'
  artifact_name    TEXT,              -- task/playbook/plan name, or command
  parameters       JSONB NOT NULL DEFAULT '{}'::jsonb,
  target_spec      JSONB NOT NULL,    -- what the user selected: nodes, groups, filter
  resolved_targets JSONB NOT NULL,    -- list of node_ids at submission time
  started_at       TIMESTAMPTZ NOT NULL,
  ended_at         TIMESTAMPTZ,
  overall_status   TEXT NOT NULL DEFAULT 'running'   -- 'running' | 'succeeded' | 'failed' | 'aborted' | 'timed_out'
);
CREATE INDEX executions_initiated_idx ON executions (initiated_by, started_at DESC);
CREATE INDEX executions_integration_idx ON executions (integration_id, started_at DESC);

CREATE TABLE execution_targets (
  id               UUID PRIMARY KEY,
  execution_id     UUID NOT NULL REFERENCES executions(id) ON DELETE CASCADE,
  node_id          UUID REFERENCES nodes(id) ON DELETE SET NULL,
  target_identity  JSONB NOT NULL,
  exit_status      INTEGER,
  duration_ms      INTEGER,
  transcript       BYTEA,              -- compressed stdout+stderr
  transcript_meta  JSONB NOT NULL DEFAULT '{}'::jsonb,  -- { stdout_bytes, stderr_bytes, truncated }
  finished_at      TIMESTAMPTZ
);
CREATE INDEX execution_targets_exec_idx ON execution_targets (execution_id);
CREATE INDEX execution_targets_node_idx ON execution_targets (node_id, finished_at DESC);
```

Transcript is stored as gzipped bytea. At 10,000 nodes, typical execution against a group of 50 produces 50 rows; transcripts are typically under a megabyte each. Streaming output is *not* held indefinitely in memory by the LiveView — it lives in the `Vigil.Core.Execution.Stream` GenServer's buffer during the run, and is flushed to the DB at completion.

Retention: configurable per `DM-1102` via `settings.retention.executions_days`. Default unbounded (the PRD sets the default; operators override).

## 4.6 Reports

Reports are first-class persisted records (`DM-702`, `DM-703`).

```sql
CREATE TABLE reports (
  id                UUID PRIMARY KEY,
  tenant_id         UUID NOT NULL,
  node_id           UUID REFERENCES nodes(id) ON DELETE SET NULL,
  integration_id    UUID NOT NULL REFERENCES integrations(id) ON DELETE CASCADE,
  plugin_id         TEXT NOT NULL,
  source_report_id  TEXT NOT NULL,       -- e.g., Puppet report ID
  started_at        TIMESTAMPTZ NOT NULL,
  ended_at          TIMESTAMPTZ,
  summary           JSONB NOT NULL,      -- counts, durations, etc.
  phases            JSONB,               -- per-phase timings (PUP-704)
  mode              TEXT,                -- 'normal' | 'noop' | 'dry_run'
  status            TEXT NOT NULL,       -- 'succeeded' | 'failed' | 'with_changes'
  environment       TEXT,
  raw               JSONB,               -- full report body for drill-down
  ingested_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT reports_source_unique UNIQUE (integration_id, source_report_id)
);
CREATE INDEX reports_node_time_idx ON reports (node_id, started_at DESC);
CREATE INDEX reports_integration_time_idx ON reports (integration_id, started_at DESC);
```

Resource-level events from a report are extracted into `journal_entries` with `group_key = reports.source_report_id`. Cross-referencing between report and its journal entries is via `group_key` on both sides.

## 4.7 Users, roles, permissions

### 4.7.1 Users

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

`password_hash` is NULL for externally authenticated users (`AUTH-104`, `DM-302`). The unique constraints match Phase 1 local auth + Phase 2 external auth (`AUTH-106`).

### 4.7.2 Sessions and tokens

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

### 4.7.3 Roles and permissions

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

## 4.8 Audit trail

Append-only table. `NFR-602`: audit entries are never modified.

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
  result           TEXT NOT NULL,       -- 'success' | 'denied' | 'error'
  correlation_id   TEXT,
  request_meta     JSONB NOT NULL DEFAULT '{}'::jsonb   -- ip, user-agent
);
CREATE INDEX audit_actor_idx ON audit_entries (tenant_id, actor_user_id, occurred_at DESC);
CREATE INDEX audit_target_idx ON audit_entries (tenant_id, target_kind, target_id, occurred_at DESC);
CREATE INDEX audit_action_idx ON audit_entries (tenant_id, action, occurred_at DESC);
```

`RBAC-304` forbids ordinary deletion. The retention policy runs as an admin-authorized scheduled job — not a regular delete path. Export (`RBAC-303`) is a read-only stream generated by a background job into a downloadable object.

## 4.9 Linking rules and settings

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

Settings includes retention (per journal / executions / audit), default timezone, branding, AI provider config (with secrets refs), etc.

## 4.10 Derived data: where it lives

Per `DM-1101`, inventory, facts, and configuration are derived, not persisted.

| Data | Runtime location | Not persisted because |
|------|------------------|----------------------|
| Node inventory list | ETS cache, keyed per integration | Always reconstructible from the source |
| Facts per node | ETS cache, keyed `{integration_id, node_id}` | Same |
| Hiera / catalog / config | ETS cache + local control-repo on disk | Same; repo is source of truth |
| Monitoring state | Very short-lived ETS cache (seconds) | Real-time; would be stale anywhere else |
| Deployment history | Either ETS + source, or persisted per integration decision | Depends on source's retention |

Journal entries extracted from events *are* persisted because they are the historical record (`DM-1102`). The extraction is idempotent — a re-fetch of the same event does not create a duplicate.

## 4.11 Migrations and tooling

- **Migrations** via `ecto_migrate`. Versioned, reversible where practical.
- **Seeding** via `priv/repo/seeds.exs` — creates the default tenant, the built-in roles, and optionally a development admin user.
- **Data generator** for testing (`TEST-902`) lives under `apps/vigil_core/lib/vigil/core/test_data.ex`. It can generate synthetic inventories at target scale.

Schema changes to the plugin contract are handled by the contract-version compatibility layer (`PLUG-602`), not by database migrations.

## 4.12 Query patterns and scale

At 10,000 nodes:

- `nodes` table: 10,000 rows. Trivial.
- `node_sources`: up to 10,000 × (number of integrations per node) ≈ 30,000 rows. Trivial.
- `journal_entries`: bounded by event volume. Estimate: 10,000 nodes × ~5 changes/day × 365 days = 18M/year. Index on `(node_id, occurred_at DESC)` keeps per-node queries fast; per-tenant global queries use `(tenant_id, occurred_at DESC)`. Partitioning by month is planned when storage grows.
- `executions`: low volume. Hundreds per day in typical deployments.
- `reports`: bounded by agent run frequency. 10,000 nodes × 48 runs/day = 480,000/day. Rolling retention of 30-90 days keeps the table in the tens-of-millions range, well within Postgres comfort.
- `audit_entries`: bounded by user activity. Low volume, retained longer.

First-page render at 10,000 nodes (`NFR-002`):

- Per-source inventory lists come from ETS cache in microseconds.
- Merging and rendering through LiveView add milliseconds.
- The bottleneck is network / external tool latency on cold cache.

Cached hits comfortably meet the 2-second target. Cold cache fallback meets the same target when the primary source is healthy (PuppetDB PQL is capable of returning 10,000 certnames with status in under a second). See [section 5](05-aggregation-and-caching.md).

---

[← Previous: Plugin Framework](03-plugin-framework.md) | [Next: Aggregation & Caching →](05-aggregation-and-caching.md)

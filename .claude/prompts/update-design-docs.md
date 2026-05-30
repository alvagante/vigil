# Prompt: Update Design Docs to Reflect PRD Grilling Decisions

Use this prompt to start a session that updates the design docs after the PRD
grilling session (commit b98c22f).

---

I'm working on Vigil — a single-node Elixir/Phoenix/LiveView/PostgreSQL
infrastructure command-and-control platform. The stack: Elixir umbrella app,
Phoenix 1.8+, LiveView 1.1+, Ecto 3.x, PostgreSQL, supervised OTP processes.

I just completed a structured PRD grilling session that produced 840 lines of
spec changes. The design docs (docs/specs/design/) need updating to reflect the
decisions made. The PRD is the source of truth for WHAT; the design docs capture
HOW in implementation terms (GenServer trees, ETS tables, Ecto schemas, PubSub
topics, LiveView architecture).

Start by reading:
- docs/specs/design/01-overview.md  (existing design overview)
- CONTEXT.md  (domain glossary — normative)
- docs/adr/0001 through 0005  (all five ADRs — key decisions)
- docs/specs/prd/12-data-model.md  (data model including execution model)
- docs/specs/prd/11-platform-requirements.md  (CACHE-006, HEALTH-104/105,
  RBAC-102/107/108/109, INV-110)
- docs/specs/prd/06-plugin-architecture.md  (§6.7 supplementary capabilities)

Then identify gaps in the design docs and propose updates for:

## 1. Node linking engine (ADR-0003)

The algorithm: multi-attribute inverted index (certname→node_id, fqdn→node_id,
hostname→node_id, ip→node_id) maintained in memory, updated incrementally on
integration cache refresh. Linking a new record = point lookups, not comparison
scan. Conflicts (two hits mapping to different node_ids) go to a manual review
queue. Index rebuilt from persisted identity records at startup.

Design doc needs: where this lives in the supervision tree, what process owns
the index, how it interacts with integration cache refresh events.

## 2. Execution data model (ADR-0004 + ADR-0005)

One Ecto schema row per target node per dispatch. All rows from the same dispatch
share an execution_group_id (UUID generated at dispatch time). Transcript stored
inline (binary), capped at 50MB, truncation marker on cap. Denied nodes produce
no execution records — audit trail owns that (ADR-0005).

Design doc needs: Ecto schema for executions and execution_groups tables, how
streaming output is written to the transcript field incrementally, how the group
aggregate status is computed.

## 3. Supplementary capabilities slot system (PRD §6.7)

Plugins declare node_tab / global_page / node_action supplementary capabilities
in their manifest. The platform mounts them at runtime in LiveView.

Design doc needs: how plugin manifests declare supplementary capabilities, how
LiveView routes node_tab and node_action slots per-node (only when the plugin is
linked to the viewed node), how global_page entries build the sidebar navigation
dynamically.

## 4. Shared integration cache (CACHE-006)

Full integration inventory cached per integration+capability, not per principal.
RBAC filter applied at presentation time in the application layer.

Design doc needs: ETS table structure for the integration cache (what keys, what
values, how source attribution is carried through), how the presentation layer
applies per-principal RBAC filtering post-cache without N queries.

## 5. Health flapping detection (HEALTH-104/105)

Rolling 30-minute window, 3+ healthy↔unhealthy transitions = flapping state.

Design doc needs: where this state machine lives (the process that owns health
checks), how transitions are counted efficiently without storing full history,
the four-state model: healthy / degraded / unhealthy / flapping.

## 6. Node lifecycle state machine (DM-1102, DM-1106–DM-1109)

Three states: Active (≥1 integration reports it) → Unreported (no integration
currently reports it) → Decommissioned (explicit admin action, tombstoned).
Decommission releases all identity claims in the linking index (ADR-0003).

Design doc needs: Ecto schema for the nodes table including lifecycle state
field, state transition triggers, how the unreported transition is detected
(integration cache refresh that no longer includes the node).

---

The design docs must remain implementation-specific (Elixir/OTP/ETS/GenServer/
Ecto/LiveView details belong here, not in the PRD). Cross-reference ADR numbers
and PRD requirement IDs where relevant so the design docs stay traceable to the
decisions that drove them.

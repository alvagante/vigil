# Spec revision session — 2026-05-11

## Trigger

Two input documents:
- `docs/specs/architectural-critique.md` — 15 issues across three tiers
- `docs/specs/editions.md` — CE/EE split and reshuffled roadmap

User asked: review, accept/push back, then implement consistently. Exception: split OIDC into CE (single-IdP, literal group mapping) and EE (multi-IdP, wildcard patterns, re-eval on every login).

## Decisions accepted without pushback

All 15 architectural critique items — no objections raised. Editions doc accepted as written with one modification (OIDC split).

## Changes by file

### New IDs introduced
- `AUTH-010` — session-touch debouncing (#3)
- `AUTH-051..057` — CE OIDC (single-IdP, literal group mapping)
- `AUTH-101..110` — re-numbered EE external auth (SAML, LDAP, multi-IdP OIDC, wildcard, re-eval, etc.)
- `RBAC-108` — bounded-query evaluation requirement (#1)
- `RBAC-305`, `RBAC-306` — audit-first ordering (#2)
- `PLUG-407..409` — explicit plugin trust model (#5)
- `CACHE-009`, `CACHE-010` — cold-start warming, no-snapshot (#6)
- `PERF-010` — multi-node cache locality (#4)
- `EXEC-106` — execution durability across restarts (#13)
- `TEST-202a` — N+1 query test requirement (#14)
- `TEST-904` — realistic fact fixture sizes (#15)
- `HEALTH-005` — canonical health-probe ownership (#12)

### PRD files modified
- `00-index.md` — edition note; reading-order row 21 updated
- `06-plugin-architecture.md` — `PLUG-407..409` trust model
- `11-platform-requirements.md` — major restructure:
  - §11.4.1 Local + session debounce (`AUTH-010`)
  - §11.4.2 OIDC CE (`AUTH-051..057`)
  - §11.4.3 Enterprise external auth EE (`AUTH-101..110`)
  - §11.5.2 added `RBAC-108`
  - §11.5.3 marked wildcard (RBAC-204) / re-eval (RBAC-205) as EE
  - §11.5.4 added `RBAC-305/306` audit-first
  - §11.7.1 added `HEALTH-005` canonical probe ownership
  - §11.8 added `PERF-010` multi-node cache locality
  - §11.2.2 added `EXEC-106` execution durability
  - §11.9 added `CACHE-009/010` cold-start warming
- `16-testing-philosophy.md` — `TEST-202a`, `TEST-904`
- `17-ai-features.md` — `MCP-202` multi-node scope; `AI-303` structured-first redaction
- `20-implementation-roadmap.md` — full rewrite of Phase 1/2 sections:
  - CE Phase 1: FS 1-14 (MCP+AI pulled forward, new FS 14 CE OIDC)
  - EE Phase 2: FS EE-1..EE-8
  - New `ROAD-106`, `ROAD-107` cross-cutting requirements
- `21-future-considerations.md` — items moved to EE retired (IDs preserved as pointers)
- `05-integration-matrix.md` — priority/phase clarification (orthogonal to edition)

### Design files modified
- `00-index.md` — edition boundary note
- `01-overview.md` — extension behaviours listed in core; EE app inventory
- `02-application-topology.md` — `vigil_auth_oidc` in CE umbrella; EE apps noted as external
- `03-plugin-framework.md` — new §3.9 plugin trust model (`PLUG-407..409`)
- `04-data-model.md` — audit pending state, partial_transcript column, §4.11 tenant scoping enforcement (context macro + test-telemetry handler)
- `05-aggregation-and-caching.md` — §5.6 canonical health-probe decision; §5.10 cold-start warmer; §5.11 multi-node cache locality
- `06-execution-and-streaming.md` — §6.2.1 audit-first pipeline; §6.2.2 audit reconciliation; §6.2.8 restart durability
- `07-journal-and-events.md` — no changes (already fetch-on-demand in an earlier revision)
- `08-auth-rbac.md` — full restructure:
  - §8.1.1 Local (CE)
  - §8.1.2 OIDC (CE, `openid_connect` directly, single-IdP, literal mapping)
  - §8.1.3 Enterprise external auth (EE)
  - §8.1.4 LDAP pooling via NimblePool (EE, addresses #7)
  - §8.1.5 API tokens
  - §8.1.6 Default role
  - §8.1.7 Coexistence
  - §8.2 Session debouncing implementation (addresses #3)
  - §8.3.3 RBAC batch loading (addresses #1)
  - §8.5 Group mapping CE literal constraint
- `10-mcp-and-ai.md` — §10.1.7 per-node rate limit scope; §10.2.4 structured-first redaction (addresses #9, #10)
- `12-deployment-and-ops.md` — §12.6 multi-node config guidance (HAProxy/nginx examples); §12.8 CPU spike correction (addresses #11, #4)
- `13-testing-strategy.md` — RBAC query-count test; realistic fact fixture generator (addresses #14, #15)

### Edition/steering files modified
- `docs/specs/editions.md` — OIDC split into CE; EE-1 renamed to "Enterprise External Authentication"; `vigil_auth_oidc` in CE umbrella; extension-point table updated
- `.kiro/steering/tech.md` — added Editions section; OIDC moved to CE in auth stack; engineering rules expanded with tenant scoping, audit ordering, RBAC purity
- `.kiro/steering/structure.md` — planned layout split into CE and EE umbrellas; dependency direction updated

## Identifier conventions

- All moved-to-EE future IDs (`FUT-101..107`, etc.) preserved as pointers per index convention ("Once assigned, an ID is not reused")
- All new IDs slot into existing prefix ranges with clear numbering

### Known deviation from the ID-stability rule

The EE external-auth renumber in `11-platform-requirements.md` §11.4.3 reuses five IDs with changed semantics. This violates the index convention ("Once assigned, an ID is not reused even if its requirement is removed"). Accepted for this spec-only snapshot because no code, tests, or external references exist yet. To revisit if/when the AUTH block is touched again:

| ID | Previous semantics | Current semantics |
|----|-------------------|-------------------|
| `AUTH-102` | generic OIDC / OAuth 2.0 | multiple concurrent OIDC providers (EE) |
| `AUTH-106` | local + external auth coexist | admin can disable local auth (EE) |
| `AUTH-107` | admin can disable local auth | multiple IdPs of different protocols concurrently (EE) |
| `AUTH-108` | multiple IdPs concurrently | wildcard group patterns (EE) |
| `AUTH-109` | IdP unavailable → sessions continue | re-evaluate groups on every login (EE) |

A cleaner future fix: move the new semantics to fresh IDs (`AUTH-111..115`) and restore the previous meanings on `AUTH-102/106/107/108/109`, leaving the CE OIDC block (`AUTH-051..057`) as-is.

## Known remaining work

None from this revision. All 15 critique items and the editions split have concrete spec text. Implementation can proceed when code lands; specs lead code per `structure.md` rule.

## Links

- Critique: `docs/specs/architectural-critique.md`
- Editions: `docs/specs/editions.md`
- Roadmap: `docs/specs/prd/20-implementation-roadmap.md`

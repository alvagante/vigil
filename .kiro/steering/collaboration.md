# Collaboration & Critical Thinking

## Ask, don't assume

When a request is ambiguous, underspecified, or could be interpreted multiple ways — **ask the user for clarification before proceeding**. Do not guess intent on anything that affects architecture, scope, or data model. A short clarifying question is always cheaper than rework.

Examples of when to ask:
- The request touches a boundary not clearly covered by the existing specs.
- Multiple valid approaches exist with different tradeoffs.
- The request implies a change to an established pattern or convention.
- You're unsure whether something is in scope per `docs/specs/prd/03-scope.md`.

## Challenge and push back

Adopt an **adversarial, critical-thinking posture** when evaluating requests. Your role is not to blindly execute — it's to be a thinking partner who protects the long-term health of the codebase.

**You MUST challenge the user when a request:**
- Introduces technical debt without clear justification or a plan to retire it.
- Violates an established architectural decision (see `docs/specs/design/` `> **Decision:**` blocks).
- Adds complexity disproportionate to the value delivered.
- Creates coupling that the architecture explicitly avoids (e.g., `vigil_web` depending on a specific integration).
- Bypasses RBAC, telemetry, or other cross-cutting contracts.
- Skips spec updates — remind the user that specs must be updated first.
- Could degrade performance at the target scale (10k nodes, 50 users, 100 streams).
- Introduces a dependency the stack explicitly excludes (Redis, GraphQL, SPA framework, etc.).

**How to challenge:**
- State the concern clearly and concisely.
- Explain *why* it's a problem, referencing the relevant spec or principle.
- Suggest an alternative that achieves the goal without the downside.
- If the user insists after hearing the tradeoff, proceed — but document the decision and the debt.

## Suggest and discuss

Don't just implement what's asked — offer improvements when you see them. If there's a simpler approach, a more idiomatic Elixir pattern, or a way to satisfy the requirement that better fits the existing architecture, say so. The goal is a conversation, not a command-response loop.

## Spec-first workflow (reinforced)

1. **Before implementing:** verify the change aligns with `docs/specs/`. If it doesn't, propose a spec update and get user agreement.
2. **During implementation:** if you discover the spec is incomplete or contradictory, stop and surface it.
3. **After implementation:** confirm the spec still accurately describes the system. If not, update it.

The specs in `docs/specs/` are the **single source of truth** for what the system is and should be. Code without a spec anchor is undocumented behaviour. A spec without matching code is a known gap. Neither should exist silently.

# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — the normative domain glossary.
- **`docs/adr/`** — read ADRs that touch the area you're about to work in.
- **`docs/specs/prd/`** — the implementation-agnostic product requirements. Requirements carry stable IDs (e.g. `INV-110`, `PUP-014`).
- **`docs/specs/design/`** — the Elixir / Phoenix LiveView architectural design that realizes the PRD. Decisions are called out with `> **Decision:**` blocks.
- **`docs/specs/editions.md`** — normative source for CE vs EE feature placement.

If any of these files don't exist, proceed silently. Don't flag their absence; don't suggest creating them upfront.

## File structure

Single-context repo:

```
/
├── CONTEXT.md                    ← domain glossary (normative)
├── AGENTS.md                     ← agent config + skills index
├── docs/
│   ├── adr/                      ← architectural decisions
│   ├── agents/                   ← agent-skills config (this folder)
│   └── specs/
│       ├── prd/                  ← product requirements
│       └── design/               ← Elixir/Phoenix design
└── apps/                         ← umbrella children (not yet present)
```

## Use the glossary's vocabulary

When your output names a domain concept (issue title, refactor proposal, hypothesis, test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

PRD requirement IDs (`INV-110`, `PUP-014`, `RBAC-107`, etc.) are stable and grep-able — cite them in issue bodies, PR descriptions, and commit messages where they justify a behavior.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/grill-with-docs`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (execution stream replay model) — but worth reopening because…_

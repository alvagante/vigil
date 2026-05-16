# AGENTS.md

Conventions for AI coding agents (Claude Code, Cursor, OpenAI Codex, etc.) working in this repo.

## Project

**Vigil** is a unified web-based command-and-control interface for hybrid infrastructure — a Phoenix LiveView application that aggregates inventory, facts, configuration, events, monitoring, reports, deployments, executions, and provisioning across heterogeneous tooling (Puppet, Ansible, Bolt, SSH, Proxmox, AWS, Azure, …) without replacing any of them.

The product ships in two editions: **Community Edition (CE, AGPL v3)** in this repository, and **Enterprise Edition (EE, commercial)** delivered as a separate private umbrella (`vigil_enterprise`) that registers into CE's extension points at runtime. See [`docs/specs/editions.md`](docs/specs/editions.md) for the placement rationale.

## Documents that govern this codebase

- [`CONTEXT.md`](CONTEXT.md) — the normative domain glossary.
- [`docs/specs/prd/`](docs/specs/prd/) — implementation-agnostic product requirements. Each requirement has a stable ID (`INV-110`, `PUP-014`).
- [`docs/specs/design/`](docs/specs/design/) — the Elixir/Phoenix LiveView architectural design that realizes the PRD.
- [`docs/adr/`](docs/adr/) — architectural decisions. Read ADRs in the area you're about to touch. If your work contradicts one, surface it explicitly.

## Agent skills

### Issue tracker

GitHub Issues in `alvagante/vigil`, via the `gh` CLI. See [`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md).

### Triage labels

Canonical labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See [`docs/agents/triage-labels.md`](docs/agents/triage-labels.md).

### Domain docs

Single-context repo. `CONTEXT.md` + `docs/adr/` at the root; PRD and design under `docs/specs/`. See [`docs/agents/domain.md`](docs/agents/domain.md).

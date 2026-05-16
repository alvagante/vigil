# Product

**Vigil** is a web-based command-and-control interface for infrastructure management. It unifies inventory, facts, configuration, events, monitoring, reports, remote execution, provisioning, and deployment visibility across heterogeneous infrastructure tooling (Puppet, Bolt, Ansible, SSH, AWS, Azure, Proxmox, etc.) into one operator UI.

## Core principles

- **Convergence, not replacement.** Vigil aggregates what existing tools know. It does not edit Puppet code, manage monitoring rules, or run CI/CD pipelines.
- **Node-centric.** Every feature resolves to "what's happening on or to a node." If it's about managing the underlying tool itself, it's out of scope.
- **Uniform plugin contract.** Built-in and community integrations follow the same interface. No special-cased internals.
- **Graceful degradation.** A failed integration yields a partial answer with a clear marker, never an error page. Cached data is served with a staleness indicator when a source is down.
- **Scale-first.** Every design choice is evaluated at the target of ~10,000 nodes, 10 concurrent users, 100 concurrent streaming executions.
- **RBAC is universal.** Web UI, MCP server, and future CLI all enforce the same permission model.

## Integration types

Nine formal types define plugin capabilities: Inventory, Facts, Configuration, Events, Monitoring, Reports, Remote Execution, Provisioning, Deployment. A plugin declares which types it supports; the platform dispatches uniformly.

## Primary users

- Infrastructure engineers, DevOps/SRE, platform team leads, on-call responders
- External AI agents via the MCP server (RBAC-respecting, read-only)

## Out of scope

Cloud cost management, metric storage, log aggregation, APM, editing of Puppet/Ansible/monitoring rules, CI/CD pipeline management, Kubernetes workload management (only node-level visibility), IAM management for cloud providers. See `docs/specs/prd/03-scope.md` for the authoritative boundary.

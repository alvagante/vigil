# ADR-0001: Community Plugin Distribution Model — Pre-Boot Placement

**Status:** Accepted  
**Date:** 2026-05-13

## Context

The PRD (`PLUG-303`) requires that community plugins be installable "as runtime-loaded packages without modifying or rebuilding the application." Two interpretations exist:

1. **True runtime loading** — a running Vigil instance discovers and hot-loads a new plugin OTP application without restart, via `:code.add_patha/1` and `Application.start/2`.
2. **Pre-boot placement** — an operator places a valid plugin OTP application directory (compiled beam files) in the configured plugin directory before starting Vigil; Vigil discovers and starts all plugins found there during its own startup sequence.

## Decision

**Pre-boot placement.** Vigil discovers community plugins at application startup, not during runtime.

## Rationale

True runtime loading of arbitrary OTP applications into a Mix release is technically possible but operationally fragile:
- Dependency conflicts between the host release and the plugin's transitive deps cannot be resolved at runtime.
- Beam file paths must be manually managed alongside a running release.
- Hot-loading untrusted OTP applications violates the trust model already documented in `PLUG-407`/`PLUG-408`.

Pre-boot placement satisfies the uniformity goal (`PLUG-301`): first-party and community plugins are treated identically at runtime, because they are all discovered in the same startup pass. The only operational difference is that enabling or disabling a community plugin requires a Vigil restart — the same restart that would be required to upgrade the application anyway.

## Consequences

- Community plugin management (install, upgrade, remove) is an operator responsibility performed before restart, not a live UI action.
- The plugin administration UI shows which plugins are loaded (discovered at startup); it does not provide install/remove controls for community plugins.
- A future "plugin marketplace" or live install feature would require revisiting this decision and implementing a proper plugin loader with dependency isolation (e.g., via separate Erlang nodes or compiled archives).
- The PRD text in `PLUG-303` should be read as "without modifying or rebuilding the Vigil application itself" — the operator prepares plugin artifacts separately and places them; Vigil does not need to be recompiled.

# 13. Testing Strategy

This section specifies how the PRD's testing philosophy (section 16) is realized in the Elixir/Phoenix codebase. The guiding question from the PRD — *"would this test catch a bug a user would notice?"* — dictates which tests we write and which we don't.

## 13.1 Test tooling

| Purpose | Tool |
|---------|------|
| Unit & integration tests | ExUnit |
| Property-based testing | StreamData + PropCheck |
| LiveView testing | Phoenix.LiveViewTest |
| End-to-end browser tests | PhoenixTest + Wallaby (with Chromedriver) |
| Coverage | ExCoveralls |
| Mocking (minimal) | Mox (behaviour-based mocks only) |
| Containerized dependencies | Docker Compose for Postgres, PuppetDB/Puppetserver, LocalStack, etc. |
| Data generation | StreamData generators in `Vigil.Core.TestData` |
| Load testing | k6 for external load; ExUnit benchmarks via Benchee for hot paths |

## 13.2 Test organization

```
apps/vigil_core/test/
├── accounts_test.exs
├── inventory/
│   ├── linker_test.exs
│   ├── linker_property_test.exs
│   └── linker_perf_test.exs            # tagged :perf, run nightly
├── journal/
│   ├── ingestor_test.exs
│   └── extraction_property_test.exs
├── rbac/
│   ├── evaluator_test.exs
│   └── evaluator_property_test.exs
└── support/
    ├── data_case.ex
    ├── factory.ex
    └── test_data.ex

apps/vigil_web/test/
├── controllers/
├── live/
│   ├── inventory_live_test.exs
│   ├── node_detail_live_test.exs
│   └── execution_live_test.exs
└── integration/
    └── flow_01_inventory_browse_test.exs    # end-to-end for FLOW-001

apps/vigil_plugin/test/
├── conformance/                         # contract conformance suite
│   ├── inventory_contract_test.exs
│   ├── execution_contract_test.exs
│   └── lifecycle_contract_test.exs
└── reference_plugin/                    # no-op plugin for PLUG-702

apps/vigil_integrations_puppet/test/
├── puppet_db_client_test.exs
├── hiera_resolver_test.exs
├── hiera_usage_analyzer_test.exs
├── event_extractor_property_test.exs
└── conformance_test.exs                 # runs the shared conformance suite against this plugin
```

Each integration app has its own test suite; the `conformance_test.exs` runs the shared behaviour-conformance tests against that plugin.

## 13.3 Test tiers

### 13.3.1 Unit tests (ExUnit, fast)

Limited to: pure functions, data transformations, policy decisions that don't need the DB.

Examples:
- PQL query builder correctness.
- Hiera hierarchy path interpolation.
- Circuit breaker state transitions (given a pure state function).
- Retry backoff timing calculations.
- Redactor pattern matching.

### 13.3.2 Integration tests (ExUnit with DB and real deps where feasible)

These are where most testing effort goes. The DB is real (PostgreSQL in a container for CI, locally for dev). External tools are real where feasible:

- **PuppetDB / Puppetserver:** run in Docker Compose, seeded with fixture data. `apps/vigil_integrations_puppet/test/fixtures/` contains canonical reports, catalogs, facts.
- **Bolt:** real Bolt binary invoked with `bolt_project_dir: "test/fixtures/bolt_project"`.
- **Ansible:** real Ansible against a local test inventory containing `localhost` with `ansible_connection=local`.
- **SSH:** dedicated sshd container exposing test hosts.
- **AWS:** `LocalStack` for Phase 1b AWS tests; cross-account tests use mocked STS.
- **Azure:** limited — Azure has no good local emulator. We use recorded-response tests (`ExVCR` or similar) for Azure plugin tests.

Each test's `setup` builds the fixture state; `on_exit` cleans up.

### 13.3.3 LiveView tests (Phoenix.LiveViewTest)

Cover the UI's user-visible behaviour without a browser:

```elixir
test "filters inventory by source", %{conn: conn, user: user} do
  seed_inventory_with_sources(user, [:puppet, :aws])

  {:ok, view, html} = live(conn |> log_in(user), ~p"/inventory")

  assert html =~ "puppet-node-1"
  assert html =~ "aws-instance-1"

  view |> element("#source-filter-puppet") |> render_click()
  html = render(view)

  assert html =~ "puppet-node-1"
  refute html =~ "aws-instance-1"
end
```

Fast (~10ms per test) and cover the large majority of UI logic.

### 13.3.4 End-to-end tests (PhoenixTest + Wallaby)

Reserved for the PRD's numbered flows (`TEST-101`, `TEST-102`). They drive real browsers against the full stack:

```elixir
# test/integration/flow_02_command_execution_test.exs
test "executes a command with streaming output", %{session: session} do
  seed_bolt_integration()

  session
  |> log_in_as("operator@example.com", "test-pass")
  |> visit("/inventory")
  |> click("web-prod-01")
  |> click_link("Execute")
  |> fill_in("Command", with: "echo hello")
  |> click_button("Submit")

  # Output appears in the streaming terminal within a few seconds
  assert_has(session, ".execution-output", text: "hello", timeout: 5_000)

  # Journal entry created
  visit(session, ~p"/inventory/node/#{node_id}")
  assert_has(session, ".journal-entry", text: "echo hello")
end
```

One test per numbered flow plus additional tests for degraded scenarios (`TEST-102`).

### 13.3.5 Property-based tests (StreamData)

Property tests cover combinatorial and invariant-preserving properties — especially the high-stakes surfaces `TEST-201..204`:

**Identity linking (`TEST-201`):**

```elixir
property "linking is stable across re-runs" do
  check all observations <- observations_generator(count_range: 1..100) do
    nodes_a = Linker.link(observations, rules: default_rules())
    nodes_b = Linker.link(Enum.shuffle(observations), rules: default_rules())

    assert canonical_names(nodes_a) == canonical_names(nodes_b)
  end
end

property "linking is idempotent" do
  check all observations <- observations_generator() do
    once = Linker.link(observations, rules: default_rules())
    twice = Linker.link(observations ++ observations, rules: default_rules())
    assert length(once) == length(twice)
  end
end

property "manual override always beats heuristic" do
  check all {obs_a, obs_b, _} <- linkable_pair_generator() do
    with_override = Linker.link([obs_a, obs_b],
                                manual_links: [unlink(obs_a, obs_b)])
    assert length(with_override) == 2
  end
end
```

**RBAC evaluation (`TEST-202`):**

```elixir
property "permissions are order-independent" do
  check all roles <- list_of(role_gen(), min_length: 1, max_length: 5),
            action <- action_gen() do
    r1 = RBAC.evaluate(roles, action)
    r2 = RBAC.evaluate(Enum.shuffle(roles), action)
    assert r1 == r2
  end
end

property "target scope filter is correctly applied" do
  check all role <- role_with_tag_scope(~w(env=dev)),
            node <- node_gen(),
            action <- action_gen() do
    expected = Enum.any?(node.tags, fn {k, v} -> "#{k}=#{v}" == "env=dev" end)
    actual = RBAC.permits?(role, action, %{targets: [node]})
    assert actual == expected
  end
end
```

**Journal event extraction (`TEST-203`):**

```elixir
property "no-op events never produce journal entries" do
  check all report <- puppet_report_generator(only_noop: true) do
    entries = EventExtractor.extract(report)
    assert entries == []
  end
end

property "events from one report share group_key" do
  check all report <- puppet_report_generator(min_changes: 2) do
    entries = EventExtractor.extract(report)
    group_keys = entries |> Enum.map(& &1.group_key) |> Enum.uniq()
    assert length(group_keys) == 1
    assert hd(group_keys) == report.id
  end
end

property "re-ingest of same report creates no duplicates" do
  check all report <- puppet_report_generator() do
    Journal.ingest(report)
    count_first = Journal.count_for(report.node)
    Journal.ingest(report)
    count_second = Journal.count_for(report.node)
    assert count_first == count_second
  end
end
```

**Cache coalescing (`TEST-204`):**

```elixir
property "concurrent identical requests produce one upstream call" do
  check all concurrency <- integer(2..20) do
    upstream = CountingUpstream.start_link()

    tasks = for _ <- 1..concurrency do
      Task.async(fn -> Dispatcher.call(:test_int, :inventory, :list, %{}) end)
    end
    Enum.map(tasks, &Task.await/1)

    assert CountingUpstream.call_count(upstream) == 1
  end
end
```

### 13.3.6 Resilience tests (`TEST-301..304`)

Explicit failure-injection tests:

```elixir
describe "circuit breaker" do
  test "trips after consecutive failures" do
    mock_upstream(fail: true, count: 5)

    for _ <- 1..5 do
      assert {:error, _} = Dispatcher.call(int, :inventory, :list, %{})
    end

    assert {:error, %{message: "circuit breaker open"}} =
      Dispatcher.call(int, :inventory, :list, %{})
  end

  test "recovers after cooldown on probe success" do
    mock_upstream(fail: true, count: 5)
    trip_breaker()
    mock_upstream(fail: false)
    :timer.sleep(cooldown_ms() + 100)

    assert {:ok, _} = Dispatcher.call(int, :inventory, :list, %{})
  end
end

describe "streaming reconnect" do
  test "no lost output on reconnect" do
    {:ok, view, _} = live(conn, ~p"/executions/#{exec_id}")

    simulate_chunks(1..5)
    html1 = render(view)

    simulate_disconnect(view)
    simulate_chunks(6..10)
    simulate_reconnect(view)

    html2 = render(view)

    for i <- 1..10, do: assert html2 =~ "chunk-#{i}"
  end
end

describe "plugin isolation" do
  test "misbehaving plugin does not crash platform" do
    install_broken_plugin()

    result = Dispatcher.call(broken_int, :inventory, :list, %{})
    assert {:error, _} = result

    # Other integrations still work
    assert {:ok, _} = Dispatcher.call(good_int, :inventory, :list, %{})
  end
end
```

### 13.3.7 Plugin conformance tests (`TEST-401..403`)

The suite under `apps/vigil_plugin/test/conformance/` defines a `test_all_implementations` macro. Each plugin's `conformance_test.exs` is two lines:

```elixir
defmodule Vigil.Integrations.Puppet.ConformanceTest do
  use Vigil.Plugin.Conformance.Test,
    plugin: Vigil.Integrations.Puppet,
    fixture_config: "test/fixtures/conformance_config.json"
end
```

The macro generates all the conformance cases. Running `mix test` for the plugin runs its specific tests plus conformance.

The reference no-op plugin (`PLUG-702`) exists specifically as a test fixture. It passes the full conformance suite with trivial implementations, serving as the "platform is sane" smoke test.

### 13.3.8 Performance tests (`TEST-701..703`)

Tagged `:perf`, run in the nightly pipeline:

```elixir
@tag :perf
test "inventory renders within 2 seconds at 10k nodes" do
  seed_inventory(10_000, sources: [:puppet, :aws])

  start = System.monotonic_time(:millisecond)
  {:ok, _view, _html} = live(conn, ~p"/inventory")
  elapsed = System.monotonic_time(:millisecond) - start

  assert elapsed < 2_000, "First render took #{elapsed}ms"
end

@tag :perf
test "100 concurrent executions without dropped output" do
  targets = for i <- 1..100, do: insert(:node, name: "target-#{i}")

  tasks = for t <- targets do
    Task.async(fn ->
      {:ok, exec} = Executions.submit(admin(), command: "echo test", targets: [t.id])
      await_completion(exec.id, timeout: 30_000)
    end)
  end

  results = Enum.map(tasks, &Task.await(&1, 60_000))
  assert Enum.all?(results, & &1.output == "test\n")
end
```

Measured in CI with latency percentiles recorded (`TEST-703`). Regressions > 20% fail the build.

### 13.3.9 Security tests (`TEST-801..804`)

- **RBAC bypass attempts:** tests that attempt to reach resources via every surface (web, API, MCP) without the required permission; all must be denied.
- **Secret leakage:** tests that seed plugin configs with known secret values and verify they never appear in logs, UI output, audit entries, or AI prompts.
- **Command allowlist bypass:** malformed and pattern-bypass attempts.
- **Auth brute force:** rate limiter trips after N attempts; lockout honored; logs captured.

### 13.3.10 Test data realism (`TEST-901..903`)

`Vigil.Core.TestData` generates realistic data at target scale:

```elixir
def generate_inventory(count, opts) do
  for i <- 1..count do
    %{
      certname: "host-#{:rand.uniform(100_000)}.example.com",
      fqdn: "host-#{i}.region-#{opts[:region] || "us-east"}.example.com",
      facts: %{
        "os" => %{"distro" => %{"codename" => Enum.random(~w(jammy focal bookworm))}},
        "kernel" => "Linux",
        "processors" => %{"count" => Enum.random([2, 4, 8, 16])},
        "memory" => %{"total" => Enum.random(["4G", "8G", "16G", "32G"])}
      },
      groups: Enum.take_random(~w(production staging dev webservers dbservers), 2)
    }
  end
end
```

Fixtures include the awkward cases (`TEST-903`):

- Nodes with missing attributes.
- Nodes with conflicting attributes across sources (same certname, different OS).
- Groups with overlapping membership across sources.
- Users with multiple group-mapped roles.

## 13.4 What we explicitly do NOT test

Per PRD `TEST-501..506`, these categories are off the table:

- Trivial CRUD tests that the type system or Ecto changeset validations already cover.
- Mocked-API-wrapper tests where mock and assertion are written by the same author.
- Pure rendering tests without user interaction.
- Snapshot tests that fail on cosmetic changes.
- State-for-its-own-sake tests.

Code review rejects tests of these kinds.

## 13.5 Mocking strategy (`TEST-601..604`)

- **Prefer real.** Containerized Puppet, real Bolt, LocalStack for AWS, an sshd container for SSH.
- **Replay-based fixtures** (via `ExVCR` or a custom tape player) where real is infeasible (Azure, paid services).
- **Mox behaviour mocks** for narrow unit-level decisions — circuit breaker state transitions, retry policy. Only for pure decision logic.
- **No hand-written stubs for "the API returns X."** These produce false confidence.

The conformance suite runs against real fixtures specifically to avoid tautological testing.

## 13.6 CI pipeline

Per `TEST-1001`:

```
on push / PR:
├── Install deps (cached)
├── Format check (mix format --check-formatted)
├── Compile with --warnings-as-errors
├── Credo static analysis (strict)
├── Dialyzer (plt cached)
├── mix test (default tags — fast)
├── Plugin contract conformance
├── Database migration roundtrip check
└── Coverage report

on main / nightly:
├── Full mix test (including :integration)
├── Performance suite (:perf)
├── E2E (Wallaby) suite
├── Resilience soak test (1-hour load against a test integration)
├── Mutation testing on high-stakes suites (RBAC, linker)
└── Upload coverage
```

Test failures block merge (`TEST-1003`). No "known-failing" tests are tolerated; a failing test is either fixed or removed with rationale in the commit message.

## 13.7 Developer workflow

Local runs:

- `mix test` — fast subset (unit + essential integration).
- `mix test --include integration` — full integration suite.
- `mix test --include perf` — performance suite (requires seeded DB).
- `mix test --include e2e` — Wallaby E2E (requires Chromedriver).

`docker compose up -d` brings up the test dependencies. Tests pick them up via environment variables set in `test.exs`.

## 13.8 Test data hygiene

- Every test that writes to DB uses `Ecto.Adapters.SQL.Sandbox` for isolation.
- Tests that spawn supervised processes tear down via `on_exit/1`.
- Wallaby tests have their own session management and clean cookies.
- CI environments reset DB between runs to catch cross-test pollution.

## 13.9 Testing the tests (`TEST-1101..1103`)

- Code review explicitly considers whether each test would catch a bug.
- Mutation testing (`Muzak` or similar) runs nightly on RBAC, linking, event extraction — the high-stakes suites. Surviving mutants trigger investigation.
- A test that passes against a deliberately broken build is removed (`TEST-1102`).

## 13.10 Summary

Our testing strategy is shaped by three commitments:

1. **Cover the behaviour that matters.** End-to-end flows, property-based invariants for complex logic, resilience under failure.
2. **Prefer real dependencies.** The closer to production, the more valuable the signal.
3. **Avoid false confidence.** Skip tests that can't catch real bugs; test the behaviour, not the implementation.

The architecture supports this: BEAM process isolation lets us write realistic integration tests without heavy mocking; LiveView's server rendering lets us assert on HTML directly; PostgreSQL SQL Sandbox keeps integration tests fast without sacrificing realism.

---

[← Previous: Deployment & Ops](12-deployment-and-ops.md) | [↑ Back to index](00-index.md)

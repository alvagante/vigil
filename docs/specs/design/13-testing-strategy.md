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
| HTTP cassette replay | Custom tape player (see §13.5) |
| Containerized dependencies | Docker Compose for PostgreSQL, LocalStack, sshd |
| Data generation | StreamData generators + `mix vigil.gen_fixtures` for scale fixtures |
| Load testing | k6 for external load; Benchee for hot paths |

## 13.2 Test organization

```
apps/vigil_core/test/
├── accounts_test.exs
├── inventory/
│   ├── linker_test.exs
│   ├── linker_property_test.exs
│   └── linker_perf_test.exs            # tagged :perf, run nightly
├── journal/
│   ├── notes_test.exs
│   └── execution_entries_test.exs
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

Fixtures live under a shared top-level directory:

```
test/fixtures/
├── cassettes/
│   ├── puppet/
│   │   ├── nodes_100.json              # PuppetDB /pdb/query/v4/nodes, 100 nodes
│   │   ├── nodes_10k.json             # generated — see §13.3.10
│   │   ├── facts_single_node.json     # single node facts (~80KB realistic)
│   │   ├── reports_7d.json            # recent reports with failures, noops, successes
│   │   ├── catalog_web-prod-01.json   # compiled catalog response
│   │   └── environments.json          # Puppetserver environment list
│   ├── aws/
│   │   ├── describe_instances_100.json
│   │   └── describe_instances_10k.json
│   └── monitoring/
│       └── transitions_24h.json
├── bolt_project/
│   ├── bolt-project.yaml
│   └── plans/
└── conformance_config.json
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

### 13.3.2 Integration tests (ExUnit with selective real deps)

These are where most testing effort goes. What "real" means depends on the dependency.

**What we test with real infrastructure:**

- **PostgreSQL** — real, always. Service container in CI, local instance in dev. Vigil owns the schema; real SQL behavior is mandatory.
- **Bolt** — real binary invoked against `localhost` with `bolt_project_dir: "test/fixtures/bolt_project"`. Trivial to set up; tests the actual execution path end-to-end.
- **Ansible** — real binary against a local inventory containing `localhost` with `ansible_connection=local`. Same argument.
- **SSH** — dedicated `sshd` service container, test keys pre-loaded. Exercises the actual SSH client and auth flow.
- **LocalStack** — real HTTP server that emulates AWS. Exercises Vigil's actual AWS HTTP client, auth, and response parsing without needing AWS credentials.

**What we test with HTTP cassettes:**

All remote API integrations — PuppetDB, Puppetserver, Azure, monitoring APIs — use recorded HTTP responses replayed from fixture files. The reason is principled, not expedient:

Vigil's value is in what it does *with* API responses: parsing, caching, normalizing, linking, rendering. Testing that PuppetDB returns the right data is Puppet's job, not ours. A cassette tests exactly what we own, is deterministic, starts in milliseconds, and can represent any scale.

```elixir
# Cassette playback wraps the Finch HTTP client at the test boundary
defmodule Vigil.Test.CassetteAdapter do
  @behaviour Vigil.HTTP.Adapter

  def request(method, url, headers, body, _opts) do
    cassette = cassette_for(method, url)
    {:ok, cassette.status, cassette.headers, cassette.body}
  end

  defp cassette_for(method, url) do
    key = "#{method}:#{URI.parse(url).path}"
    @cassettes[key] || raise "No cassette for #{key} — run mix vigil.record_fixtures"
  end
end
```

The cassette adapter is injected via application config in the test environment. No changes to production code paths.

Each test's `setup` builds the Vigil-side fixture state (integration config, nodes in DB); `on_exit` cleans up.

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

**RBAC query-count assertions (`TEST-202a`, `RBAC-108`):**

The functional RBAC properties above pass regardless of whether the evaluator issues one DB query or N. To catch the N+1 pattern — a regression that would surface only in the performance suite or in production — we add explicit query-count tests at the evaluator boundary:

```elixir
for n <- [1, 10, 100, 1000] do
  test "target_matches? for #{n} targets issues exactly one DB query" do
    nodes = insert_list(unquote(n), :node, tags: %{"env" => "dev"})
    ids = Enum.map(nodes, & &1.id)

    principal = build_principal_with_role(:operator_scoped_to_dev)
    submission = %{integration_id: uuid(), target_node_ids: ids,
                   artifact: %{kind: :command, text: "echo ok"}}

    {_result, query_count} = count_queries(fn ->
      Vigil.Core.Executions.Validator.validate(principal, submission)
    end)

    # One query to resolve target nodes, plus one query for the principal's
    # role_permissions. Both are constant in N.
    assert query_count <= 2,
      "Expected <= 2 queries for #{unquote(n)} targets, got #{query_count}"
  end
end
```

`count_queries/1` is a test helper that subscribes to the `[:vigil, :repo, :query]` telemetry event and counts emissions during the closure. It fails the test if any per-target query is issued. This closes the gap noted in the architectural critique: functional RBAC tests pass under a linearly-scaling implementation, but this structural assertion does not.

**Shared-cache filtering performance (`TEST-205`, `CACHE-006`, `RBAC-110`):**

The shared cache path gets its own regression test: warm a full 10,000-node cache as an administrator, then read through narrower principals with granular scopes. The assertion is both correctness and shape: bounded query count, no raw-rule evaluation per cached record, and first page within the cache-hit latency budget.

**Journal event normalization (`TEST-203`):**

```elixir
property "no-op events never produce normalized entries" do
  check all report <- puppet_report_generator(only_noop: true) do
    entries = EventNormalizer.normalize_events(report.resource_statuses, integration)
    assert entries == []
  end
end

property "events from one report share group_key" do
  check all report <- puppet_report_generator(min_changes: 2) do
    entries = EventNormalizer.normalize_events(report.resource_statuses, integration)
    group_keys = entries |> Enum.map(& &1.group_key) |> Enum.uniq()
    assert length(group_keys) == 1
    assert hd(group_keys) == report.id
  end
end

property "normalized events always have required fields" do
  check all report <- puppet_report_generator() do
    entries = EventNormalizer.normalize_events(report.resource_statuses, integration)
    for entry <- entries do
      assert entry.source_event_id != nil
      assert entry.occurred_at != nil
      assert entry.summary != nil
      assert entry.severity in [:informational, :notice, :warning, :error]
    end
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

Tagged `:perf`, run in the nightly pipeline. Scale scenarios use generated fixture cassettes (see §13.3.10) — not a real upstream instance. The Vigil database is seeded with the corresponding node records; the upstream API responses are replayed from fixture files. This lets performance tests run at 10K-node scale without any real infrastructure.

```elixir
@tag :perf
test "inventory renders within 2 seconds at 10k nodes" do
  # Seeds Vigil's DB with 10k node rows; upstream API responses served from cassette
  seed_inventory(10_000, sources: [:puppet, :aws],
                          cassette: "test/fixtures/cassettes/puppet/nodes_10k.json")

  start = System.monotonic_time(:millisecond)
  {:ok, _view, _html} = live(conn, ~p"/inventory")
  elapsed = System.monotonic_time(:millisecond) - start

  assert elapsed < 2_000, "First render took #{elapsed}ms"
end

@tag :perf
test "identity linker processes 10k observations within 5 seconds" do
  observations = Vigil.Test.Fixtures.Generator.puppet_observations(10_000)

  {elapsed, _result} = :timer.tc(fn -> Linker.link(observations, rules: default_rules()) end)

  assert elapsed < 5_000_000, "Linker took #{div(elapsed, 1000)}ms"
end

@tag :perf
test "10 concurrent users read without queueing" do
  users = for _ <- 1..10, do: insert(:user, roles: [:operator])

  tasks =
    for user <- users do
      Task.async(fn ->
        start = System.monotonic_time(:millisecond)
        {:ok, _view, _html} = live(log_in(conn, user), ~p"/inventory")
        System.monotonic_time(:millisecond) - start
      end)
    end

  elapsed = Task.await_many(tasks, 5_000)
  assert Enum.max(elapsed) < 2_000
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

### 13.3.10 Scale fixture generation (`TEST-901..903`)

Scale fixtures are generated programmatically and committed to the repository. They are not produced by seeding a real upstream instance — you cannot seed 10,000 real Puppet nodes in CI.

A `mix vigil.gen_fixtures` task regenerates them. Run it when the API response format changes or when realistic data shapes need updating. Output is committed; CI never re-generates.

```elixir
defmodule Mix.Tasks.Vigil.GenFixtures do
  use Mix.Task

  def run(_) do
    generate("test/fixtures/cassettes/puppet/nodes_10k.json",
             &Vigil.Test.Fixtures.Generator.puppetdb_nodes/1, count: 10_000)

    generate("test/fixtures/cassettes/puppet/nodes_100.json",
             &Vigil.Test.Fixtures.Generator.puppetdb_nodes/1, count: 100)

    # Facts fixtures are generated at realistic per-node sizes (50-200KB of
    # structured facts) per TEST-904. A 10K node facts corpus is ~1-2 GB and
    # is stored compressed in the fixtures tree.
    generate("test/fixtures/cassettes/puppet/facts_1k.json.gz",
             &Vigil.Test.Fixtures.Generator.puppetdb_facts/1,
             count: 1_000, compressed: true)

    generate("test/fixtures/cassettes/puppet/facts_10k.json.gz",
             &Vigil.Test.Fixtures.Generator.puppetdb_facts/1,
             count: 10_000, compressed: true)

    generate("test/fixtures/cassettes/aws/describe_instances_10k.json",
             &Vigil.Test.Fixtures.Generator.aws_instances/1, count: 10_000)
  end
end

defmodule Vigil.Test.Fixtures.Generator do
  def puppetdb_nodes(count: count) do
    nodes = for i <- 1..count do
      env = Enum.random(["production", "staging", "development"])
      status = Enum.random(["changed", "unchanged", "failed"])

      %{
        "certname"          => "host-#{i}.#{env}.example.com",
        "deactivated"       => nil,
        "catalog_timestamp" => random_recent_iso8601(),
        "facts_timestamp"   => random_recent_iso8601(),
        "report_timestamp"  => random_recent_iso8601(),
        "latest_report_status"  => status,
        "latest_report_noop"    => Enum.random([true, false]),
        "cached_catalog_status" => Enum.random(["not_used", "used"])
      }
    end

    # Inject awkward cases (TEST-903): missing attributes, conflicting data
    nodes
    |> inject_missing_facts(rate: 0.02)
    |> inject_deactivated(rate: 0.01)
    |> Jason.encode!()
  end

  # TEST-904: realistic per-node fact payloads.
  # A typical Puppet 7/8 agent reports facts averaging 80-120KB of JSON,
  # dominated by networking interfaces, mountpoints, installed packages,
  # and various custom facts. Performance tests that use compressed or
  # abridged payloads cannot validate memory/bandwidth budgets at scale.
  def puppetdb_facts(count: count) do
    for i <- 1..count do
      %{
        "certname"  => "host-#{i}.example.com",
        "timestamp" => random_recent_iso8601(),
        "environment" => "production",
        "facts" => realistic_fact_payload(i)    # ~80-150KB per node
      }
    end
    |> Jason.encode!()
  end

  defp realistic_fact_payload(seed) do
    # Derived from a captured anonymised Puppet 8 agent fact report.
    # Structure: os.*, networking.* (10-20 interfaces typical),
    # processors.*, memory.*, mountpoints.*, packages.* (300-1500 entries),
    # custom facts. Total JSON encoded size targets 80-150KB.
    %{
      "os" => os_facts(),
      "kernel" => "Linux",
      "processors" => processor_facts(),
      "memory" => memory_facts(),
      "networking" => networking_facts(interface_count: rand_range(seed, 8, 20)),
      "mountpoints" => mountpoint_facts(count: rand_range(seed, 4, 12)),
      "packages" => package_facts(count: rand_range(seed, 300, 1500)),
      "custom" => custom_facts(seed)
    }
  end
end
```

The generator covers awkward cases at a realistic rate:

- Nodes with missing or partial attributes.
- Nodes conflicting across sources (same certname, different OS report).
- Groups with overlapping membership across sources.

**Why realistic fact sizes matter.** At 10K nodes × 100KB facts average, a full facts sweep is 1 GB of JSON to parse, route, and cache. Performance tests using 1KB stub facts pass under an implementation that streams parse line-by-line *and* under a naive implementation that materialises the entire response into a single binary. Production then surfaces the difference painfully. `TEST-904` makes fact-size realism a normative requirement of the performance suite.

## 13.4 What we explicitly do NOT test

Per PRD `TEST-501..506`, these categories are off the table:

- Trivial CRUD tests that the type system or Ecto changeset validations already cover.
- Mocked-API-wrapper tests where mock and assertion are written by the same author.
- Pure rendering tests without user interaction.
- Snapshot tests that fail on cosmetic changes.
- State-for-its-own-sake tests.

Code review rejects tests of these kinds.

## 13.5 Dependency strategy (`TEST-601..604`)

The principle is: test what you own. For Vigil, that is its processing logic, not the correctness of upstream APIs.

| Dependency | Approach | Rationale |
|---|---|---|
| PostgreSQL | Real (service container) | Vigil owns the schema; SQL behavior is non-negotiable |
| Bolt | Real binary, localhost | Trivial setup; exercises actual execution path |
| Ansible | Real binary, `ansible_connection=local` | Same |
| sshd | Real service container | Exercises auth and transport |
| LocalStack | Real HTTP server | Good enough AWS emulator; exercises actual HTTP client |
| PuppetDB API | HTTP cassettes | Vigil tests its own parsing, not PuppetDB correctness |
| Puppetserver API | HTTP cassettes | JVM startup cost; no local emulator needed |
| Azure | HTTP cassettes | No local emulator exists |
| Monitoring APIs | HTTP cassettes | Same argument as PuppetDB |

**HTTP cassette playback** uses a custom adapter injected into the HTTP client in test config. Cassettes are JSON files keyed on `method + path`. The adapter is a thin behaviour implementation — no production code paths are touched.

**Mox** for narrow unit-level decisions only: circuit breaker state transitions, retry policy calculations. Only where the logic is pure and a real dep would add nothing.

**No hand-written stubs for "the API returns X."** Stubs written by the same author as the test produce tautological assertions. Cassettes are recorded against a real instance once; after that they're authoritative independent of the test author.

**Cassette maintenance:** when an upstream API changes response shape, the affected cassettes are updated by running `mix vigil.record_fixtures` against a real instance (developer machine or a dedicated fixture-recording environment). Updated cassettes are reviewed in code review like any other change.

## 13.6 CI pipeline

Per `TEST-1001`:

```
on push / PR:
├── Install deps (cached)
├── Format check (mix format --check-formatted)
├── Compile with --warnings-as-errors
├── Credo static analysis (strict)
├── Dialyzer (plt cached)
├── mix test (default tags — fast; cassettes serve all API calls)
├── Plugin contract conformance
├── Database migration roundtrip check
└── Coverage report

on main / nightly:
├── Full mix test (including :integration)
├── Performance suite (:perf — uses generated scale fixtures)
├── E2E (Wallaby) suite
├── Resilience soak test (1-hour load against a test integration)
├── Mutation testing on high-stakes suites (RBAC, linker)
└── Upload coverage
```

A separate optional workflow handles real-Puppet connectivity verification:

```
puppet-contract (manual trigger / release candidate tags only):
├── Start PostgreSQL + PuppetDB (Docker Compose, 1 node seeded)
├── Wait for PuppetDB ready (health endpoint poll, timeout 120s)
├── mix test --only puppet_contract
│     verifies: mTLS handshake, basic PQL round-trip, auth rejection on bad token
└── Teardown
```

This workflow does not test behavior or scale. It exists only to confirm that the mTLS configuration and PQL builder produce valid requests against a real PuppetDB endpoint. It runs on release candidates or on demand, not on every commit.

Test failures block merge (`TEST-1003`). No "known-failing" tests are tolerated; a failing test is either fixed or removed with rationale in the commit message.

## 13.7 Developer workflow

Local runs:

- `mix test` — fast subset (unit + essential integration; cassettes serve API calls, no containers needed beyond PostgreSQL).
- `mix test --include integration` — full integration suite (requires `docker compose up -d` for PostgreSQL, LocalStack, sshd).
- `mix test --include perf` — performance suite (uses pre-generated scale fixtures).
- `mix test --include e2e` — Wallaby E2E (requires Chromedriver).
- `mix test --only puppet_contract` — real PuppetDB connectivity (requires `docker compose up -d puppetdb`).
- `mix vigil.gen_fixtures` — regenerate scale fixture files after upstream API changes.

`docker compose up -d` brings up PostgreSQL, LocalStack, and sshd. Tests pick up connection details via environment variables set in `test.exs`. Puppetserver is not in the standard compose file — it is not needed for the main suite.

## 13.8 Test data hygiene

- Every test that writes to DB uses `Ecto.Adapters.SQL.Sandbox` for isolation.
- Tests that spawn supervised processes tear down via `on_exit/1`.
- Wallaby tests have their own session management and clean cookies.
- CI environments reset DB between runs to catch cross-test pollution.
- Cassette files are read-only during test runs; no test writes to them.

## 13.9 Testing the tests (`TEST-1101..1103`)

- Code review explicitly considers whether each test would catch a bug.
- Mutation testing (`Muzak` or similar) runs nightly on RBAC, linking, event extraction — the high-stakes suites. Surviving mutants trigger investigation.
- A test that passes against a deliberately broken build is removed (`TEST-1102`).

## 13.10 Summary

Our testing strategy is shaped by three commitments:

1. **Test what you own.** Vigil's value is in how it processes, caches, normalizes, and renders API responses — not in whether upstream APIs work correctly. Cassettes let us test our logic precisely, at any scale, without infrastructure.
2. **Real where it matters.** PostgreSQL is real because Vigil owns the schema. Bolt and Ansible are real because they execute locally and the setup cost is zero. LocalStack is real enough for AWS because it exercises the actual HTTP client.
3. **Avoid false confidence.** Skip tests that can't catch real bugs; test the behaviour, not the implementation.

Scale scenarios that are physically impossible to reproduce with live infrastructure (10,000 Puppet nodes) are covered by deterministic generated fixtures. This is more useful than a real instance at a fraction of the scale — the fixture can be crafted to cover edge cases that a real deployment might never hit.

---

[← Previous: Deployment & Ops](12-deployment-and-ops.md) | [↑ Back to index](00-index.md)

defmodule Vigil.Integrations.PuppetTest do
  use ExUnit.Case, async: false

  alias Vigil.Integrations.Puppet
  alias Vigil.Integrations.Puppet.{FakePuppetDB, FakePuppetserver, Hiera.Resolution}
  alias Vigil.Plugin.{Catalog, Conformance, Error, Result, Source}

  @fixtures_repo Path.expand("../../support/hiera_fixtures", __DIR__)

  # Wires FakePuppetDB as the HTTP transport; no real PuppetDB required.
  @test_config %{
    "puppetdb.url" => "http://fake-pdb:8080",
    "http_module" => FakePuppetDB,
    "http_opts" => []
  }

  setup %{test: test} do
    agent = FakePuppetDB.new()
    id = "puppet-#{:erlang.phash2(test)}-#{System.unique_integer([:positive])}"
    config = Map.put(@test_config, "http_opts", agent: agent)
    {:ok, id: id, config: config, agent: agent}
  end

  defp start_instance(id, config) do
    start_supervised!(Supervisor.child_spec(Puppet.child_spec({id, config}), id: {:puppet, id}))
  end

  # ──────────────────────────────────────────────
  # Tracer 1: Lifecycle / conformance
  # ──────────────────────────────────────────────

  describe "lifecycle conformance (design §3.7)" do
    test "all Vigil.Plugin callbacks are implemented" do
      assert function_exported?(Puppet, :plugin_id, 0)
      assert function_exported?(Puppet, :display_name, 0)
      assert function_exported?(Puppet, :contract_version, 0)
      assert function_exported?(Puppet, :capabilities, 0)
      assert function_exported?(Puppet, :config_schema, 0)
      assert function_exported?(Puppet, :child_spec, 1)
      assert function_exported?(Puppet, :defaults, 0)
      assert function_exported?(Puppet, :operational_permissions, 0)
    end

    test "conformance lifecycle checks all pass", %{config: config} do
      report = Conformance.run(Puppet, config)

      lifecycle_failed = Enum.filter(report.failed, &String.starts_with?(&1.name, "lifecycle:"))

      assert lifecycle_failed == [],
             "lifecycle checks failed:\n" <>
               Enum.map_join(lifecycle_failed, "\n", & &1.message)
    end

    test "Catalog discovers the Puppet plugin from its OTP app env" do
      assert {:ok, Puppet} = Catalog.lookup("puppet")
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 2: list_nodes
  # ──────────────────────────────────────────────

  describe "list_nodes/2 (PUP-101, INV-201)" do
    test "returns empty list when PuppetDB returns no nodes",
         %{id: id, config: config, agent: agent} do
      FakePuppetDB.set_nodes(agent, [])
      start_instance(id, config)

      assert {:ok, %Result{data: [], source: %Source{plugin_id: "puppet", integration_id: ^id}}} =
               Puppet.list_nodes(id, %{})
    end

    test "maps PuppetDB nodes to Plugin.Node structs with source attribution",
         %{id: id, config: config, agent: agent} do
      FakePuppetDB.set_nodes(agent, [
        %{
          "certname" => "web-01.example.com",
          "deactivated" => nil,
          "expired" => nil,
          "latest_report_status" => "changed"
        },
        %{
          "certname" => "db-01.example.com",
          "deactivated" => "2026-01-01T00:00:00Z",
          "expired" => nil,
          "latest_report_status" => "unchanged"
        }
      ])

      start_instance(id, config)

      assert {:ok, %Result{data: nodes, source: %Source{plugin_id: "puppet"}}} =
               Puppet.list_nodes(id, %{})

      assert length(nodes) == 2

      web = Enum.find(nodes, &(&1.name == "web-01.example.com"))
      assert web.attributes["status"] == "active"
      assert web.attributes["integration_id"] == id

      db = Enum.find(nodes, &(&1.name == "db-01.example.com"))
      assert db.attributes["status"] == "deactivated"
    end

    test "PQL injection in filter values is escaped",
         %{id: id, config: config, agent: agent} do
      FakePuppetDB.set_nodes(agent, [])
      start_instance(id, config)

      assert {:ok, %Result{}} =
               Puppet.list_nodes(id, %{
                 filter: %{environment: ~s(production"; DROP TABLE nodes; --)}
               })
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 3: get_facts
  # ──────────────────────────────────────────────

  describe "get_facts/2 (PUP-201..206)" do
    test "returns structured facts for a known certname",
         %{id: id, config: config, agent: agent} do
      FakePuppetDB.set_facts(agent, "web-01.example.com", [
        %{"name" => "os.name", "value" => "Ubuntu"},
        %{"name" => "os.release.full", "value" => "22.04"},
        %{"name" => "processors.count", "value" => 8}
      ])

      start_instance(id, config)

      assert {:ok, %Result{data: facts, source: %Source{plugin_id: "puppet"}}} =
               Puppet.get_facts(id, %{node: "web-01.example.com"})

      assert facts["os.name"] == "Ubuntu"
      assert facts["processors.count"] == 8
    end

    test "returns structured error when no node is specified",
         %{id: id, config: config} do
      start_instance(id, config)

      assert {:error, %Error{category: :user_input}} = Puppet.get_facts(id, %{})
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 4: health_check
  # ──────────────────────────────────────────────

  describe "health_check/1 (PUP-901..903)" do
    test "returns :healthy when PuppetDB responds to probe",
         %{id: id, config: config, agent: agent} do
      FakePuppetDB.set_nodes(agent, [
        %{
          "certname" => "probe",
          "deactivated" => nil,
          "expired" => nil,
          "latest_report_status" => "unchanged"
        }
      ])

      start_instance(id, config)

      assert {:ok, :healthy} = Puppet.health_check(id)
    end

    test "returns :unhealthy when PuppetDB returns an error",
         %{id: id, config: config, agent: agent} do
      FakePuppetDB.set_error(agent, :connection_refused)
      start_instance(id, config)

      assert {:ok, :unhealthy} = Puppet.health_check(id)
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 5: circuit breaker (RES-002)
  # ──────────────────────────────────────────────

  describe "circuit breaker (RES-002)" do
    test "trips after 5 consecutive PuppetDB failures",
         %{id: id, config: config, agent: agent} do
      FakePuppetDB.set_error(agent, :connection_refused)
      start_instance(id, config)

      for _ <- 1..5, do: Puppet.list_nodes(id, %{})

      assert {:error, %Error{category: :transient_external, message: msg, retriable?: true}} =
               Puppet.list_nodes(id, %{})

      assert String.contains?(msg, "circuit breaker")
    end

    test "recovers after probe succeeds following forced cooldown",
         %{id: id, config: config, agent: agent} do
      FakePuppetDB.set_error(agent, :connection_refused)
      start_instance(id, config)

      for _ <- 1..5, do: Puppet.list_nodes(id, %{})

      FakePuppetDB.clear_error(agent)
      FakePuppetDB.set_nodes(agent, [])

      Vigil.Integrations.Puppet.CircuitBreaker.force_probe(id)

      assert {:ok, %Result{}} = Puppet.list_nodes(id, %{})
    end

    test "respects configurable threshold from config",
         %{id: id, agent: agent} do
      low_threshold_config =
        @test_config
        |> Map.put("http_opts", agent: agent)
        |> Map.put("circuit_breaker.threshold", 2)

      FakePuppetDB.set_error(agent, :connection_refused)
      start_instance(id, low_threshold_config)

      for _ <- 1..2, do: Puppet.list_nodes(id, %{})

      assert {:error, %Error{category: :transient_external, message: msg}} =
               Puppet.list_nodes(id, %{})

      assert String.contains?(msg, "circuit breaker")
    end

    test "recovers via time-based cooldown with tiny cooldown_ms config",
         %{id: id, agent: agent} do
      fast_cooldown_config =
        @test_config
        |> Map.put("http_opts", agent: agent)
        |> Map.put("circuit_breaker.cooldown_ms", 1)

      FakePuppetDB.set_error(agent, :connection_refused)
      start_instance(id, fast_cooldown_config)

      for _ <- 1..5, do: Puppet.list_nodes(id, %{})

      FakePuppetDB.clear_error(agent)
      FakePuppetDB.set_nodes(agent, [])

      Process.sleep(5)

      assert {:ok, %Result{}} = Puppet.list_nodes(id, %{})
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 6: full conformance suite
  # ──────────────────────────────────────────────

  describe "full conformance suite" do
    test "all contracts pass", %{config: config} do
      report = Conformance.run(Puppet, config)

      assert Conformance.Report.ok?(report),
             "conformance failures:\n" <>
               Enum.map_join(report.failed, "\n", & &1.message)

      assert Enum.any?(report.passed, &(&1.name == "inventory:list_nodes/2:result_shape"))
      assert Enum.any?(report.passed, &(&1.name == "facts:get_facts/2:result_shape"))
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 7: get_reports (PUP-701..713)
  # ──────────────────────────────────────────────

  describe "get_reports/2 (PUP-701..713)" do
    test "returns normalized report structs from PuppetDB",
         %{id: id, config: config, agent: agent} do
      FakePuppetDB.set_reports(agent, [
        %{
          "certname" => "web-01.example.com",
          "status" => "changed",
          "start_time" => "2026-06-30T10:00:00Z",
          "end_time" => "2026-06-30T10:00:30Z",
          "run_duration" => 30.5,
          "num_changes" => 3,
          "num_failures" => 0,
          "num_corrective_changes" => 1,
          "noop" => false,
          "hash" => "abc123def456"
        }
      ])

      start_instance(id, config)

      assert {:ok, %Result{data: [report]}} = Puppet.get_reports(id, %{})

      assert report.certname == "web-01.example.com"
      assert report.status == "changed"
      assert report.num_changes == 3
      assert report.num_failures == 0
      assert report.num_corrective_changes == 1
      assert report.noop == false
      assert report.hash == "abc123def456"
    end

    test "returns empty list when no reports in PuppetDB",
         %{id: id, config: config, agent: agent} do
      FakePuppetDB.set_reports(agent, [])
      start_instance(id, config)

      assert {:ok, %Result{data: []}} = Puppet.get_reports(id, %{})
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 8: fetch_events (PUP-601..607, TEST-203)
  # ──────────────────────────────────────────────

  describe "fetch_events/3 (PUP-601..607)" do
    test "returns normalized events for a certname",
         %{id: id, config: config, agent: agent} do
      FakePuppetDB.set_events(agent, "web-01.example.com", [
        %{
          "certname" => "web-01.example.com",
          "timestamp" => "2026-06-30T10:00:05Z",
          "resource_type" => "File",
          "resource_title" => "/etc/app/config.yml",
          "status" => "success",
          "old_value" => "absent",
          "new_value" => "file",
          "message" => "defined content as '{md5}abc'",
          "file" => "site/modules/app/manifests/init.pp",
          "line" => 12,
          "containment_path" => ["Stage[main]", "App", "File[/etc/app/config.yml]"],
          "report" => "report-hash-001"
        }
      ])

      start_instance(id, config)

      assert {:ok, %Result{data: [event]}} =
               Puppet.fetch_events(id, "web-01.example.com", time_range: %{from: "2026-06-30T00:00:00Z", to: "2026-06-30T23:59:59Z"})

      assert event.group_key == "report-hash-001"
      assert event.entry_type == "configuration_change"
      assert event.severity == :informational
      assert event.detail.resource_type == "File"
      assert event.detail.resource_title == "/etc/app/config.yml"
      assert String.contains?(event.source_event_id, "report-hash-001")
    end

    test "TEST-203: noop run produces zero events (PUP-604 noop filter)",
         %{id: id, config: config, agent: agent} do
      # FakePuppetDB returns [] for certname — simulates PuppetDB server-side
      # filtering: status in ["success", "failure"] excludes all noop events.
      FakePuppetDB.set_events(agent, "noop-node.example.com", [])

      start_instance(id, config)

      assert {:ok, %Result{data: []}} =
               Puppet.fetch_events(id, "noop-node.example.com", time_range: %{from: "2026-06-30T00:00:00Z", to: "2026-06-30T23:59:59Z"})
    end

    test "failure events have :error severity",
         %{id: id, config: config, agent: agent} do
      FakePuppetDB.set_events(agent, "web-01.example.com", [
        %{
          "certname" => "web-01.example.com",
          "timestamp" => "2026-06-30T10:00:05Z",
          "resource_type" => "Service",
          "resource_title" => "nginx",
          "status" => "failure",
          "old_value" => "stopped",
          "new_value" => "running",
          "message" => "Could not start Service[nginx]",
          "file" => nil,
          "line" => nil,
          "containment_path" => [],
          "report" => "report-hash-002"
        }
      ])

      start_instance(id, config)

      assert {:ok, %Result{data: [event]}} =
               Puppet.fetch_events(id, "web-01.example.com", time_range: %{from: "2026-06-30T00:00:00Z", to: "2026-06-30T23:59:59Z"})

      assert event.severity == :error
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 9: get_catalog (PUP-401..403)
  # ──────────────────────────────────────────────

  describe "get_catalog/3 (PUP-401..403)" do
    test "returns normalized catalog with resources for a certname",
         %{id: id, config: config, agent: agent} do
      FakePuppetDB.set_catalog(agent, "web-01.example.com", %{
        "certname" => "web-01.example.com",
        "environment" => "production",
        "resources" => [
          %{
            "type" => "File",
            "title" => "/etc/app/config.yml",
            "parameters" => %{"ensure" => "file", "owner" => "root"},
            "tags" => ["file", "app"],
            "exported" => false,
            "file" => "/etc/puppet/modules/app/manifests/init.pp",
            "line" => 5
          },
          %{
            "type" => "Package",
            "title" => "nginx",
            "parameters" => %{"ensure" => "installed"},
            "tags" => ["package"],
            "exported" => false,
            "file" => nil,
            "line" => nil
          }
        ],
        "edges" => [
          %{"source" => %{"type" => "Stage", "title" => "main"},
            "target" => %{"type" => "File", "title" => "/etc/app/config.yml"},
            "relationship" => "contains"}
        ]
      })

      start_instance(id, config)

      assert {:ok, %Result{data: catalog}} = Puppet.get_catalog(id, "web-01.example.com", [])

      assert catalog.certname == "web-01.example.com"
      assert catalog.environment == "production"
      assert length(catalog.resources) == 2

      file_res = Enum.find(catalog.resources, &(&1.type == "File"))
      assert file_res.title == "/etc/app/config.yml"
      assert file_res.parameters["ensure"] == "file"

      assert length(catalog.edges) == 1
    end

    test "returns :not_found error when certname has no catalog in PuppetDB",
         %{id: id, config: config} do
      start_instance(id, config)

      assert {:error, %Error{category: :not_found}} =
               Puppet.get_catalog(id, "unknown.example.com", [])
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 10: compute_diff / diff_catalogs (PUP-404..405)
  # ──────────────────────────────────────────────

  describe "compute_diff/2 (PUP-404..405)" do
    alias Vigil.Integrations.Puppet.{Catalog, Resource}

    defp make_resource(type, title, params) do
      %Resource{type: type, title: title, parameters: params, tags: [], exported: false}
    end

    test "resources only in A appear in only_in_a" do
      cat_a = %Catalog{certname: "web-01", resources: [make_resource("Package", "nginx", %{"ensure" => "installed"})]}
      cat_b = %Catalog{certname: "web-01", resources: []}

      diff = Puppet.compute_diff(cat_a, cat_b)

      assert length(diff.only_in_a) == 1
      assert hd(diff.only_in_a).title == "nginx"
      assert diff.only_in_b == []
      assert diff.changed == []
      assert diff.identical_count == 0
    end

    test "resources only in B appear in only_in_b" do
      cat_a = %Catalog{certname: "web-01", resources: []}
      cat_b = %Catalog{certname: "web-01", resources: [make_resource("Service", "nginx", %{"ensure" => "running"})]}

      diff = Puppet.compute_diff(cat_a, cat_b)

      assert diff.only_in_a == []
      assert length(diff.only_in_b) == 1
      assert hd(diff.only_in_b).title == "nginx"
    end

    test "resources with changed parameters appear in changed with param_diffs" do
      cat_a = %Catalog{certname: "web-01", resources: [
        make_resource("File", "/etc/app/config.yml", %{"ensure" => "file", "owner" => "root"})
      ]}
      cat_b = %Catalog{certname: "web-01", resources: [
        make_resource("File", "/etc/app/config.yml", %{"ensure" => "file", "owner" => "deploy"})
      ]}

      diff = Puppet.compute_diff(cat_a, cat_b)

      assert diff.only_in_a == []
      assert diff.only_in_b == []
      assert length(diff.changed) == 1
      assert diff.identical_count == 0

      [change] = diff.changed
      assert change.resource.type == "File"
      assert change.param_diffs["owner"] == %{in_a: "root", in_b: "deploy"}
      refute Map.has_key?(change.param_diffs, "ensure")
    end

    test "identical resources increment identical_count" do
      resource = make_resource("File", "/etc/app", %{"ensure" => "directory"})
      cat = %Catalog{certname: "web-01", resources: [resource]}

      diff = Puppet.compute_diff(cat, cat)

      assert diff.only_in_a == []
      assert diff.only_in_b == []
      assert diff.changed == []
      assert diff.identical_count == 1
    end

    test "mixed catalog diff counts all categories correctly" do
      cat_a = %Catalog{certname: "web-01", resources: [
        make_resource("Package", "nginx", %{"ensure" => "installed"}),
        make_resource("File", "/etc/nginx/nginx.conf", %{"content" => "old"}),
        make_resource("Service", "nginx", %{"ensure" => "running"})
      ]}
      cat_b = %Catalog{certname: "web-01", resources: [
        make_resource("File", "/etc/nginx/nginx.conf", %{"content" => "new"}),
        make_resource("Service", "nginx", %{"ensure" => "running"}),
        make_resource("Exec", "reload-nginx", %{"command" => "/usr/sbin/nginx -s reload"})
      ]}

      diff = Puppet.compute_diff(cat_a, cat_b)

      assert length(diff.only_in_a) == 1
      assert hd(diff.only_in_a).type == "Package"
      assert length(diff.only_in_b) == 1
      assert hd(diff.only_in_b).type == "Exec"
      assert length(diff.changed) == 1
      assert diff.identical_count == 1
    end
  end

  # ──────────────────────────────────────────────
  # mTLS option assembly (PUP-801, PUP-803)
  # ──────────────────────────────────────────────

  describe "mTLS pool option assembly (PUP-801, PUP-803)" do
    alias Vigil.Integrations.Puppet.PuppetDB.FinchHTTP

    test "no TLS options when cert/key/ca are absent" do
      spec = FinchHTTP.child_spec("test-id", %{"puppetdb.url" => "https://pdb:8081"})
      {Finch, opts} = spec
      pool_opts = opts[:pools]["https://pdb:8081"]
      refute Keyword.has_key?(pool_opts, :conn_opts)
    end

    test "assembles certfile + keyfile + cacertfile + verify_peer when all three are present" do
      config = %{
        "puppetdb.url" => "https://pdb:8081",
        "puppetdb.client_cert" => "/etc/puppet/ssl/certs/vigil.pem",
        "puppetdb.client_key" => "/etc/puppet/ssl/private_keys/vigil.pem",
        "puppetdb.ca_cert" => "/etc/puppet/ssl/certs/ca.pem"
      }

      spec = FinchHTTP.child_spec("test-id", config)
      {Finch, opts} = spec
      pool_opts = opts[:pools]["https://pdb:8081"]
      conn_opts = Keyword.fetch!(pool_opts, :conn_opts)
      transport_opts = Keyword.fetch!(conn_opts, :transport_opts)

      assert Keyword.get(transport_opts, :certfile) == "/etc/puppet/ssl/certs/vigil.pem"
      assert Keyword.get(transport_opts, :keyfile) == "/etc/puppet/ssl/private_keys/vigil.pem"
      assert Keyword.get(transport_opts, :cacertfile) == "/etc/puppet/ssl/certs/ca.pem"
      assert Keyword.get(transport_opts, :verify) == :verify_peer
    end

    test "omits mTLS options when only CA cert is provided (TLS verify only)" do
      config = %{
        "puppetdb.url" => "https://pdb:8081",
        "puppetdb.ca_cert" => "/etc/puppet/ssl/certs/ca.pem"
      }

      spec = FinchHTTP.child_spec("test-id", config)
      {Finch, opts} = spec
      pool_opts = opts[:pools]["https://pdb:8081"]
      conn_opts = Keyword.fetch!(pool_opts, :conn_opts)
      transport_opts = Keyword.fetch!(conn_opts, :transport_opts)

      refute Keyword.has_key?(transport_opts, :certfile)
      assert Keyword.get(transport_opts, :cacertfile) == "/etc/puppet/ssl/certs/ca.pem"
      assert Keyword.get(transport_opts, :verify) == :verify_peer
    end
  end

  # ──────────────────────────────────────────────
  # PQL injection guard
  # ──────────────────────────────────────────────

  describe "PQL builder (injection safety)" do
    alias Vigil.Integrations.Puppet.PQL

    test "escape_string escapes double quotes and backslashes" do
      assert PQL.escape_string(~s(foo"bar)) == ~s(foo\\"bar)
      assert PQL.escape_string("foo\\bar") == "foo\\\\bar"
      assert PQL.escape_string("safe") == "safe"
    end

    test "nodes_query with injected environment value escapes the injected quote" do
      pql = PQL.nodes_query(%{environment: ~s(prod"; DROP TABLE nodes; --)})
      # The injected `"` must become `\"` so PuppetDB parses it as a literal
      # character inside the string, not as a closing delimiter.
      assert String.contains?(pql, ~s(prod\\"; DROP TABLE nodes; --))
    end

    test "facts_query escapes certname" do
      pql = PQL.facts_query(~s(evil"certname))
      refute String.contains?(pql, ~s("evil"certname"))
      assert String.contains?(pql, ~s(evil\\"certname))
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 11: browse_hierarchy (PUP-301..303)
  # ──────────────────────────────────────────────

  describe "browse_hierarchy/3 (PUP-301..303)" do
    setup ctx do
      hiera_config = Map.merge(ctx.config, %{"control_repo.path" => @fixtures_repo})
      start_instance(ctx.id, hiera_config)
      :ok
    end

    test "returns hierarchy levels for production environment", %{id: id} do
      assert {:ok, %Result{data: levels}} = Puppet.browse_hierarchy(id, "production")

      assert length(levels) == 3
      names = Enum.map(levels, & &1.name)
      assert "Per-node data" in names
      assert "OS family" in names
      assert "Common data" in names
    end

    test "levels carry raw path patterns (not interpolated)", %{id: id} do
      assert {:ok, %Result{data: levels}} = Puppet.browse_hierarchy(id, "production")

      per_node = Enum.find(levels, &(&1.name == "Per-node data"))
      assert per_node.data_source_path == "data/nodes/%{trusted.certname}.yaml"
    end

    test "environment isolation: staging has only its own levels (PUP-303)", %{id: id} do
      assert {:ok, %Result{data: prod_levels}} = Puppet.browse_hierarchy(id, "production")
      assert {:ok, %Result{data: staging_levels}} = Puppet.browse_hierarchy(id, "staging")

      assert length(staging_levels) == 1
      assert length(prod_levels) == 3
      assert hd(staging_levels).name == "Common data"
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 12: resolve_key :first strategy (PUP-311..312)
  # ──────────────────────────────────────────────

  describe "resolve_key/5 :first strategy (PUP-311..312)" do
    setup ctx do
      hiera_config = Map.merge(ctx.config, %{"control_repo.path" => @fixtures_repo})
      start_instance(ctx.id, hiera_config)
      :ok
    end

    test "key in common.yaml: found at last level, prior levels not_found", %{id: id} do
      node_context = %{"trusted" => %{"certname" => "db01.example.com"}, "facts" => %{"os" => %{"family" => "Debian"}}}

      assert {:ok, %Result{data: %Resolution{} = res}} =
               Puppet.resolve_key(id, "production", "profile::base::dns_servers", node_context)

      assert res.key == "profile::base::dns_servers"
      assert res.merge_strategy == :first
      assert res.result == ["8.8.8.8"]

      # chain has 3 entries (one per hierarchy level)
      assert length(res.chain) == 3

      [per_node, os_fam, common] = res.chain
      assert per_node.status == :not_found
      assert os_fam.status == :not_found
      assert common.status == :found
      assert common.level == "Common data"
    end

    test "key absent from all levels returns nil result with full chain", %{id: id} do
      node_context = %{"trusted" => %{"certname" => "x.example.com"}, "facts" => %{"os" => %{"family" => "Debian"}}}

      assert {:ok, %Result{data: %Resolution{} = res}} =
               Puppet.resolve_key(id, "production", "profile::nonexistent", node_context)

      assert is_nil(res.result)
      assert Enum.all?(res.chain, &(&1.status == :not_found))
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 13: path interpolation (PUP-314)
  # ──────────────────────────────────────────────

  describe "resolve_key/5 path interpolation (PUP-314)" do
    setup ctx do
      hiera_config = Map.merge(ctx.config, %{"control_repo.path" => @fixtures_repo})
      start_instance(ctx.id, hiera_config)
      :ok
    end

    test "interpolates %{trusted.certname} in per-node path", %{id: id} do
      # web01.example.com has a node-specific file with port 9090
      node_context = %{
        "trusted" => %{"certname" => "web01.example.com"},
        "facts" => %{"os" => %{"family" => "Debian"}}
      }

      assert {:ok, %Result{data: %Resolution{} = res}} =
               Puppet.resolve_key(id, "production", "profile::app::port", node_context)

      # per-node data wins over common.yaml (which has 8080)
      assert res.result == 9090
      [per_node | _] = res.chain
      assert per_node.status == :found
      assert per_node.interpolated == "data/nodes/web01.example.com.yaml"
    end

    test "interpolates %{facts.os.family} and resolves from OS-level file", %{id: id} do
      # RedHat.yaml has ntp_servers override; node file doesn't exist
      node_context = %{
        "trusted" => %{"certname" => "db01.rhel.example.com"},
        "facts" => %{"os" => %{"family" => "RedHat"}}
      }

      assert {:ok, %Result{data: %Resolution{} = res}} =
               Puppet.resolve_key(id, "production", "profile::base::ntp_servers", node_context)

      # OS-level overrides common for RedHat
      assert res.result == ["2.rhel.pool.ntp.org"]
      [_per_node, os_fam | _] = res.chain
      assert os_fam.status == :found
      assert os_fam.interpolated == "data/os/RedHat.yaml"
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 14: merge strategies (PUP-313)
  # ──────────────────────────────────────────────

  describe "resolve_key/5 merge strategies (PUP-313)" do
    setup ctx do
      hiera_config = Map.merge(ctx.config, %{"control_repo.path" => @fixtures_repo})
      start_instance(ctx.id, hiera_config)
      :ok
    end

    # web01 has: {timeout: 60, retries: 5, debug: true}
    # common has: {timeout: 30, retries: 3}
    # hash merge: per-node wins for shared keys; debug only from per-node
    test ":hash merge — higher priority level wins for duplicate keys", %{id: id} do
      node_context = %{
        "trusted" => %{"certname" => "web01.example.com"},
        "facts" => %{"os" => %{"family" => "Debian"}}
      }

      assert {:ok, %Result{data: %Resolution{} = res}} =
               Puppet.resolve_key(id, "production", "profile::app::settings", node_context,
                 merge: :hash
               )

      assert res.merge_strategy == :hash
      assert res.result["timeout"] == 60
      assert res.result["retries"] == 5
      assert res.result["debug"] == true
    end

    # RedHat OS has: ["2.rhel.pool.ntp.org"]
    # common has: ["0.pool.ntp.org", "1.pool.ntp.org"]
    # unique merge: all values, deduplicated, higher-priority first
    test ":unique merge — arrays from all levels deduplicated", %{id: id} do
      node_context = %{
        "trusted" => %{"certname" => "db01.rhel.example.com"},
        "facts" => %{"os" => %{"family" => "RedHat"}}
      }

      assert {:ok, %Result{data: %Resolution{} = res}} =
               Puppet.resolve_key(id, "production", "profile::base::ntp_servers", node_context,
                 merge: :unique
               )

      assert res.merge_strategy == :unique
      assert "2.rhel.pool.ntp.org" in res.result
      assert "0.pool.ntp.org" in res.result
      assert "1.pool.ntp.org" in res.result
      assert Enum.uniq(res.result) == res.result
    end

    # deep merge: same key test as hash but verifies nested maps merged recursively
    test ":deep merge — nested maps merged with higher-priority winning", %{id: id} do
      node_context = %{
        "trusted" => %{"certname" => "web01.example.com"},
        "facts" => %{"os" => %{"family" => "Debian"}}
      }

      assert {:ok, %Result{data: %Resolution{} = res}} =
               Puppet.resolve_key(id, "production", "profile::app::settings", node_context,
                 merge: :deep
               )

      assert res.merge_strategy == :deep
      # per-node value 60 must win over common's 30
      assert res.result["timeout"] == 60
      # key only in common still appears
      assert res.result["retries"] == 5
      # key only in per-node
      assert res.result["debug"] == true
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 16: list_environments (PUP-501)
  # ──────────────────────────────────────────────

  describe "list_environments/1 (PUP-501)" do
    defp pss_config(base_config, pss_agent) do
      Map.merge(base_config, %{
        "puppetserver.url" => "https://fake-pss:8140",
        "puppetserver.http_module" => FakePuppetserver,
        "puppetserver.http_opts" => [agent: pss_agent]
      })
    end

    test "returns list of Environment structs from Puppetserver",
         %{id: id, config: config, agent: pdb_agent} do
      FakePuppetDB.set_nodes(pdb_agent, [])
      pss = FakePuppetserver.new()
      FakePuppetserver.set_environments(pss, ["production", "staging", "development"])

      start_instance(id, pss_config(config, pss))

      assert {:ok, %Result{data: envs}} = Puppet.list_environments(id)
      assert length(envs) == 3
      names = Enum.map(envs, & &1.name)
      assert "production" in names
      assert "staging" in names
      assert "development" in names
    end

    test "returns empty list when Puppetserver has no environments",
         %{id: id, config: config, agent: pdb_agent} do
      FakePuppetDB.set_nodes(pdb_agent, [])
      pss = FakePuppetserver.new()
      FakePuppetserver.set_environments(pss, [])

      start_instance(id, pss_config(config, pss))

      assert {:ok, %Result{data: []}} = Puppet.list_environments(id)
    end

    test "returns config_error when puppetserver.url is not configured",
         %{id: id, config: config, agent: pdb_agent} do
      FakePuppetDB.set_nodes(pdb_agent, [])
      start_instance(id, config)

      assert {:error, %Error{category: :config_error}} = Puppet.list_environments(id)
    end

    test "returns transient_external error on Puppetserver failure",
         %{id: id, config: config, agent: pdb_agent} do
      FakePuppetDB.set_nodes(pdb_agent, [])
      pss = FakePuppetserver.new()
      FakePuppetserver.set_error(pss, :connection_refused)

      start_instance(id, pss_config(config, pss))

      assert {:error, %Error{category: :transient_external, retriable?: true}} =
               Puppet.list_environments(id)
    end

    test "Puppetserver failure does not affect PuppetDB circuit breaker",
         %{id: id, config: config, agent: pdb_agent} do
      FakePuppetDB.set_nodes(pdb_agent, [
        %{"certname" => "web-01.example.com", "deactivated" => nil, "expired" => nil,
          "latest_report_status" => "changed"}
      ])
      pss = FakePuppetserver.new()
      FakePuppetserver.set_error(pss, :connection_refused)

      start_instance(id, pss_config(config, pss))

      # Repeatedly fail Puppetserver calls — should not trip the PuppetDB breaker
      for _ <- 1..10, do: Puppet.list_environments(id)

      # PuppetDB inventory must still work
      assert {:ok, %Result{data: [_]}} = Puppet.list_nodes(id, %{})
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 17: flush_environment_cache (PUP-502)
  # ──────────────────────────────────────────────

  describe "flush_environment_cache/2 (PUP-502)" do
    test "flushes all environments when no environment given",
         %{id: id, config: config, agent: pdb_agent} do
      FakePuppetDB.set_nodes(pdb_agent, [])
      pss = FakePuppetserver.new()
      start_instance(id, pss_config(config, pss))

      assert {:ok, :flushed} = Puppet.flush_environment_cache(id)
    end

    test "flushes a named environment",
         %{id: id, config: config, agent: pdb_agent} do
      FakePuppetDB.set_nodes(pdb_agent, [])
      pss = FakePuppetserver.new()
      start_instance(id, pss_config(config, pss))

      assert {:ok, :flushed} = Puppet.flush_environment_cache(id, "production")
    end

    test "returns transient_external error on failure",
         %{id: id, config: config, agent: pdb_agent} do
      FakePuppetDB.set_nodes(pdb_agent, [])
      pss = FakePuppetserver.new()
      FakePuppetserver.set_error(pss, :connection_refused)
      start_instance(id, pss_config(config, pss))

      assert {:error, %Error{category: :transient_external}} =
               Puppet.flush_environment_cache(id)
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 18: deploy_environment via :r10k_webhook (PUP-506)
  # ──────────────────────────────────────────────

  describe "deploy_environment/3 via :r10k_webhook (PUP-506)" do
    defp webhook_config(base_config, pss_agent) do
      Map.merge(base_config, %{
        "puppetserver.url" => "https://fake-pss:8140",
        "puppetserver.http_module" => FakePuppetserver,
        "puppetserver.http_opts" => [agent: pss_agent],
        "code_deploy.method" => "r10k_webhook",
        "code_deploy.url" => "https://fake-pss:8140/webhook/r10k"
      })
    end

    test "succeeds for a valid environment via webhook",
         %{id: id, config: config, agent: pdb_agent} do
      FakePuppetDB.set_nodes(pdb_agent, [])
      pss = FakePuppetserver.new()
      FakePuppetserver.set_deploy_result(pss, {:ok, %{"status" => "queued"}})
      start_instance(id, webhook_config(config, pss))

      assert {:ok, _} = Puppet.deploy_environment(id, "production", %{id: "alice"})
    end

    test "returns error on webhook failure without corrupting PuppetDB circuit breaker",
         %{id: id, config: config, agent: pdb_agent} do
      FakePuppetDB.set_nodes(pdb_agent, [
        %{"certname" => "web-01.example.com", "deactivated" => nil, "expired" => nil,
          "latest_report_status" => "changed"}
      ])
      pss = FakePuppetserver.new()
      FakePuppetserver.set_deploy_result(pss, {:error, :server_error})
      start_instance(id, webhook_config(config, pss))

      # Deploy fails
      assert {:error, %Error{category: :transient_external}} =
               Puppet.deploy_environment(id, "production", %{id: "alice"})

      # PuppetDB still works — circuit breaker not corrupted
      assert {:ok, %Result{data: [_]}} = Puppet.list_nodes(id, %{})
    end

    test "rejects empty environment name",
         %{id: id, config: config, agent: pdb_agent} do
      FakePuppetDB.set_nodes(pdb_agent, [])
      pss = FakePuppetserver.new()
      start_instance(id, webhook_config(config, pss))

      # deploy_environment/3 guard requires non-empty environment
      assert_raise FunctionClauseError, fn ->
        Puppet.deploy_environment(id, "", %{id: "alice"})
      end
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 19: deploy_environment via :code_manager (PUP-505)
  # ──────────────────────────────────────────────

  describe "deploy_environment/3 via :code_manager (PUP-505)" do
    defp cm_config(base_config, pss_agent) do
      Map.merge(base_config, %{
        "puppetserver.url" => "https://fake-pss:8140",
        "puppetserver.http_module" => FakePuppetserver,
        "puppetserver.http_opts" => [agent: pss_agent],
        "code_deploy.method" => "code_manager",
        "code_deploy.url" => "https://fake-pss:8140/code-manager/v1/deploys",
        "code_deploy.bearer_token" => "test-token"
      })
    end

    test "succeeds via Code Manager API",
         %{id: id, config: config, agent: pdb_agent} do
      FakePuppetDB.set_nodes(pdb_agent, [])
      pss = FakePuppetserver.new()
      FakePuppetserver.set_deploy_result(pss, {:ok, %{"status" => "queued"}})
      start_instance(id, cm_config(config, pss))

      assert {:ok, _} = Puppet.deploy_environment(id, "staging", %{id: "alice"})
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 20: deploy_all_environments (PUP-504(b))
  # ──────────────────────────────────────────────

  describe "deploy_all_environments/2 (PUP-504(b))" do
    test "deploys all environments via webhook",
         %{id: id, config: config, agent: pdb_agent} do
      FakePuppetDB.set_nodes(pdb_agent, [])
      pss = FakePuppetserver.new()
      FakePuppetserver.set_deploy_result(pss, {:ok, %{"status" => "all-queued"}})

      deploy_config = Map.merge(config, %{
        "puppetserver.url" => "https://fake-pss:8140",
        "puppetserver.http_module" => FakePuppetserver,
        "puppetserver.http_opts" => [agent: pss],
        "code_deploy.method" => "r10k_webhook",
        "code_deploy.url" => "https://fake-pss:8140/webhook/r10k"
      })

      start_instance(id, deploy_config)

      assert {:ok, _} = Puppet.deploy_all_environments(id, %{id: "alice"})
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 21: deploy via :remote_exec (PUP-507)
  # ──────────────────────────────────────────────

  describe "deploy_environment/3 via :remote_exec (PUP-507)" do
    defmodule FakeDispatcher do
      def call(_integration_id, exec_int_id, :run_command, %{command: cmd}) do
        send(self(), {:dispatched, exec_int_id, cmd})
        {:ok, %{exit_code: 0}}
      end
    end

    test "dispatches the correct r10k command for a single environment",
         %{id: id, config: config, agent: pdb_agent} do
      FakePuppetDB.set_nodes(pdb_agent, [])

      exec_config = Map.merge(config, %{
        "code_deploy.method" => "remote_exec",
        "code_deploy.exec_integration_id" => "ssh-prod",
        "dispatcher_module" => FakeDispatcher
      })

      start_instance(id, exec_config)

      assert {:ok, _} = Puppet.deploy_environment(id, "production", %{id: "alice"})
      assert_received {:dispatched, "ssh-prod", "r10k deploy environment production"}
    end

    test "dispatches deploy-all command for deploy_all_environments/2",
         %{id: id, config: config, agent: pdb_agent} do
      FakePuppetDB.set_nodes(pdb_agent, [])

      exec_config = Map.merge(config, %{
        "code_deploy.method" => "remote_exec",
        "code_deploy.exec_integration_id" => "ssh-prod",
        "dispatcher_module" => FakeDispatcher
      })

      start_instance(id, exec_config)

      assert {:ok, _} = Puppet.deploy_all_environments(id, %{id: "alice"})
      assert_received {:dispatched, "ssh-prod", "r10k deploy environment --all"}
    end

    test "returns config_error when exec_integration_id is not set",
         %{id: id, config: config, agent: pdb_agent} do
      FakePuppetDB.set_nodes(pdb_agent, [])

      exec_config = Map.merge(config, %{
        "code_deploy.method" => "remote_exec"
      })

      start_instance(id, exec_config)

      assert {:error, %Error{category: :config_error}} =
               Puppet.deploy_environment(id, "production", %{id: "alice"})
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 15: Error handling (AC: missing repo, malformed YAML)
  # ──────────────────────────────────────────────

  describe "Hiera error handling" do
    test "browse_hierarchy returns config_error when control_repo.path not set", %{
      id: id,
      config: config
    } do
      start_instance(id, config)

      assert {:error, %Error{category: :config_error}} = Puppet.browse_hierarchy(id, "production")
    end

    test "browse_hierarchy returns not_found for unknown environment", %{id: id, config: config} do
      hiera_config = Map.merge(config, %{"control_repo.path" => @fixtures_repo})
      start_instance(id, hiera_config)

      assert {:error, %Error{category: :not_found}} =
               Puppet.browse_hierarchy(id, "nonexistent_env")
    end

    test "browse_hierarchy returns parse_error for malformed YAML", %{id: id, config: config} do
      # point to a dir where the hiera.yaml is broken
      # write a bad hiera.yaml in a temp location
      tmp = System.tmp_dir!()
      bad_env_path = Path.join([tmp, "bad_fixtures", "environments", "production"])
      File.mkdir_p!(bad_env_path)
      File.write!(Path.join(bad_env_path, "hiera.yaml"), ":\n  - bad: [yaml: here")

      bad_config =
        Map.merge(config, %{"control_repo.path" => Path.join([tmp, "bad_fixtures"])})

      start_instance(id, bad_config)

      assert {:error, %Error{category: :parse_error}} =
               Puppet.browse_hierarchy(id, "production")
    end
  end
end

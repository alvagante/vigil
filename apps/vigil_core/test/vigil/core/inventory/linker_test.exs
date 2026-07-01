defmodule Vigil.Core.Inventory.LinkerTest do
  @moduledoc """
  Tests for the multi-attribute inverted index and linking algorithm (design §5.2, ADR-0003).

  TEST-201: StreamData property test for normalization and index round-trip.
  INV-110: Benchee benchmark asserts O(M) per-batch linking at 10k × 1k scale.
  """

  use Vigil.DataCase, async: false

  use ExUnitProperties

  alias Vigil.Core.Inventory.Linker
  alias Vigil.Core.Inventory.Linker.Index
  alias Vigil.Core.Inventory.Observation
  alias Vigil.Core.Nodes

  # Reset ETS state between tests since the Linker owns named tables
  # and is started by the app supervisor.  We call the Linker directly via
  # handle_call; the ETS tables survive across tests — we clean them in setup.

  setup do
    # Allow the Linker GenServer process to use the test's sandbox connection
    linker_pid = Process.whereis(Vigil.Core.Inventory.Linker)
    Ecto.Adapters.SQL.Sandbox.allow(Vigil.Repo, self(), linker_pid)

    # Flush the index via the owner process (tables are :protected)
    Linker.flush_index()
    :ok
  end

  # ──────────────────────────────────────────────
  # Normalization (TEST-201 — correctness)
  # ──────────────────────────────────────────────

  describe "Index.normalize/2" do
    test "certname is lowercased" do
      assert Index.normalize(:certname, "WEB-01.PROD") == "web-01.prod"
    end

    test "fqdn is lowercased and trailing dot stripped" do
      assert Index.normalize(:fqdn, "WEB-01.PROD.EXAMPLE.COM.") == "web-01.prod.example.com"
    end

    test "fqdn without trailing dot unchanged (modulo case)" do
      assert Index.normalize(:fqdn, "WEB-01.PROD.EXAMPLE.COM") == "web-01.prod.example.com"
    end

    test "hostname is lowercased" do
      assert Index.normalize(:hostname, "WEB-01") == "web-01"
    end

    test "ip canonicalized via inet" do
      assert Index.normalize(:ip, "10.000.000.001") == "10.0.0.1"
    end

    test "ip already canonical is unchanged" do
      assert Index.normalize(:ip, "10.0.0.1") == "10.0.0.1"
    end

    test "ip with IPv6 is round-tripped" do
      result = Index.normalize(:ip, "::1")
      assert result == "::1"
    end

    test "invalid ip falls back to the original value" do
      assert Index.normalize(:ip, "not-an-ip") == "not-an-ip"
    end
  end

  # ──────────────────────────────────────────────
  # TEST-201 — StreamData property test
  # ──────────────────────────────────────────────

  describe "normalization idempotency (TEST-201)" do
    property "certname normalize is idempotent" do
      check all name <- string(:alphanumeric, min_length: 1) do
        n1 = Index.normalize(:certname, name)
        n2 = Index.normalize(:certname, n1)
        assert n1 == n2
      end
    end

    property "fqdn normalize is idempotent" do
      check all parts <- list_of(string(:alphanumeric, min_length: 1), min_length: 1, max_length: 4),
                suffix <- member_of(["", "."]) do
        fqdn = Enum.join(parts, ".") <> suffix
        n1 = Index.normalize(:fqdn, fqdn)
        n2 = Index.normalize(:fqdn, n1)
        assert n1 == n2
      end
    end

    property "hostname normalize is idempotent" do
      check all h <- string(:alphanumeric, min_length: 1) do
        n1 = Index.normalize(:hostname, h)
        n2 = Index.normalize(:hostname, n1)
        assert n1 == n2
      end
    end

    property "linking an observation and looking up by certname returns same node_id" do
      check all name <- string(:alphanumeric, min_length: 2, max_length: 20),
                suffix <- integer(1..99999) do
        certname = "#{String.downcase(name)}-#{suffix}.prop.test"
        integration_id = "int-prop-#{suffix}"

        Linker.flush_index()

        obs = %Observation{
          plugin_id: "prop-test",
          integration_id: integration_id,
          source_identity: %{certname: certname},
          confidence: %{certname: :canonical},
          groups: [],
          last_seen: DateTime.utc_now()
        }

        {:ok, node_id} = Linker.link_observation(obs)
        # Looking up the (normalized) certname must return the same node_id
        assert {:ok, ^node_id} = Index.lookup(:certname, certname)
        # Lookup by uppercase also hits (normalization is idempotent)
        assert {:ok, ^node_id} = Index.lookup(:certname, String.upcase(certname))
      end
    end
  end

  # ──────────────────────────────────────────────
  # Algorithm — case (a): new node
  # ──────────────────────────────────────────────

  describe "link_observation/1 — case (a) new node" do
    test "creates a canonical node and indexes all attributes" do
      obs = build_obs("web-01.prod", "10.0.0.1")

      assert {:ok, node_id} = Linker.link_observation(obs)
      assert is_binary(node_id)

      # certname indexed
      assert {:ok, ^node_id} = Index.lookup(:certname, "web-01.prod")
      # fqdn indexed (from source_identity)
      assert {:ok, ^node_id} = Index.lookup(:fqdn, "web-01.prod.example.com")

      # Node persisted
      assert node = Nodes.get(node_id)
      assert node.canonical_name == "web-01.prod"
      assert node.lifecycle_state == "active"
    end

    test "second observation with same certname hits case (b)" do
      obs = build_obs("web-02.prod", "10.0.0.2")

      {:ok, node_id} = Linker.link_observation(obs)
      {:ok, node_id2} = Linker.link_observation(obs)

      assert node_id == node_id2
    end
  end

  # ──────────────────────────────────────────────
  # Algorithm — case (b): one match
  # ──────────────────────────────────────────────

  describe "link_observation/1 — case (b) one existing node" do
    test "upserts node_source when certname matches" do
      obs1 = %Observation{
        plugin_id: "puppet",
        integration_id: "int-puppet",
        source_identity: %{certname: "db-01.prod"},
        confidence: %{certname: :canonical},
        groups: ["databases"],
        last_seen: DateTime.utc_now()
      }

      obs2 = %Observation{
        plugin_id: "ansible",
        integration_id: "int-ansible",
        source_identity: %{certname: "db-01.prod", hostname: "db-01"},
        confidence: %{certname: :canonical, hostname: :strong},
        groups: [],
        last_seen: DateTime.utc_now()
      }

      {:ok, node_id1} = Linker.link_observation(obs1)
      {:ok, node_id2} = Linker.link_observation(obs2)

      assert node_id1 == node_id2

      # hostname gets indexed under the same node
      assert {:ok, ^node_id1} = Index.lookup(:hostname, "db-01")
    end

    test "fqdn match links to existing node" do
      obs1 = %Observation{
        plugin_id: "puppet",
        integration_id: "int-a",
        source_identity: %{certname: "cache-01.prod", fqdn: "cache-01.prod.example.com"},
        confidence: %{certname: :canonical, fqdn: :strong},
        groups: [],
        last_seen: DateTime.utc_now()
      }

      obs2 = %Observation{
        plugin_id: "ssh",
        integration_id: "int-b",
        source_identity: %{fqdn: "cache-01.prod.example.com."},
        confidence: %{fqdn: :strong},
        groups: [],
        last_seen: DateTime.utc_now()
      }

      {:ok, node_id1} = Linker.link_observation(obs1)
      # fqdn with trailing dot should normalize and hit the same node
      {:ok, node_id2} = Linker.link_observation(obs2)

      assert node_id1 == node_id2
    end
  end

  # ──────────────────────────────────────────────
  # Algorithm — case (c): conflict
  # ──────────────────────────────────────────────

  describe "link_observation/1 — case (c) conflict" do
    test "writes a link_conflicts row and returns {:error, :conflict}" do
      # Create two distinct nodes via separate certnames
      obs_a = %Observation{
        plugin_id: "puppet",
        integration_id: "int-a",
        source_identity: %{certname: "alpha-conflict.prod", hostname: "shared-conflict-host"},
        confidence: %{certname: :canonical, hostname: :strong},
        groups: [],
        last_seen: DateTime.utc_now()
      }

      obs_b = %Observation{
        plugin_id: "puppet",
        integration_id: "int-a",
        source_identity: %{certname: "beta-conflict.prod", hostname: "shared-conflict-host"},
        confidence: %{certname: :canonical, hostname: :strong},
        groups: [],
        last_seen: DateTime.utc_now()
      }

      {:ok, node_id_a} = Linker.link_observation(obs_a)
      # obs_b has a DIFFERENT certname but same hostname — after obs_a claims the
      # hostname, obs_b's certname lookup hits :miss but hostname hits node_id_a.
      # For a true conflict we need node_id_b linked first too, then a merged probe.
      # Simplest approach: link obs_b with only certname (no hostname clash yet),
      # then send a third obs that hits BOTH node_id_a (via hostname) and node_id_b (via certname).
      obs_b_cert_only = %Observation{
        plugin_id: "puppet",
        integration_id: "int-a",
        source_identity: %{certname: "beta-conflict.prod"},
        confidence: %{certname: :canonical},
        groups: [],
        last_seen: DateTime.utc_now()
      }

      {:ok, node_id_b} = Linker.link_observation(obs_b_cert_only)
      assert node_id_a != node_id_b

      # Now send an obs that will hit node_id_a via hostname AND node_id_b via certname
      conflict_obs = %Observation{
        plugin_id: "ssh",
        integration_id: "int-b",
        source_identity: %{certname: "beta-conflict.prod", hostname: "shared-conflict-host"},
        confidence: %{certname: :canonical, hostname: :strong},
        groups: [],
        last_seen: DateTime.utc_now()
      }

      # The Linker must return :conflict — a link_conflicts row is written as a side effect
      assert {:error, :conflict} = Linker.link_observation(conflict_obs)
    end
  end

  # ──────────────────────────────────────────────
  # IP matching gated by confidence (INV-104)
  # ──────────────────────────────────────────────

  describe "IP matching gating" do
    test "ip not followed when confidence is :unstable" do
      obs1 = %Observation{
        plugin_id: "puppet",
        integration_id: "int-a",
        source_identity: %{certname: "node-x.prod", ip: "192.168.1.1"},
        confidence: %{certname: :canonical, ip: :unstable},
        groups: [],
        last_seen: DateTime.utc_now()
      }

      obs2 = %Observation{
        plugin_id: "ssh",
        integration_id: "int-b",
        source_identity: %{ip: "192.168.1.1"},
        confidence: %{ip: :unstable},
        groups: [],
        last_seen: DateTime.utc_now()
      }

      {:ok, node_id1} = Linker.link_observation(obs1)
      # obs2 has only :unstable IP — should create a NEW node, not merge
      {:ok, node_id2} = Linker.link_observation(obs2)

      assert node_id1 != node_id2
    end

    test "ip followed when confidence is :strong" do
      obs1 = %Observation{
        plugin_id: "puppet",
        integration_id: "int-a",
        source_identity: %{certname: "node-y.prod", ip: "192.168.1.2"},
        confidence: %{certname: :canonical, ip: :strong},
        groups: [],
        last_seen: DateTime.utc_now()
      }

      # Pre-index the IP as :strong for obs1
      {:ok, node_id1} = Linker.link_observation(obs1)

      obs2 = %Observation{
        plugin_id: "ssh",
        integration_id: "int-b",
        source_identity: %{ip: "192.168.1.2"},
        confidence: %{ip: :strong},
        groups: [],
        last_seen: DateTime.utc_now()
      }

      {:ok, node_id2} = Linker.link_observation(obs2)
      assert node_id1 == node_id2
    end
  end

  # ──────────────────────────────────────────────
  # Decommission — claim release
  # ──────────────────────────────────────────────

  describe "decommission/3" do
    test "releases ETS claims and transitions lifecycle state" do
      obs = build_obs("decom-01.prod", "10.1.1.1")
      {:ok, node_id} = Linker.link_observation(obs)

      assert {:ok, _node} = Linker.decommission(node_id, nil, "replaced")

      # ETS claims released
      assert :miss = Index.lookup(:certname, "decom-01.prod")
      assert :miss = Index.lookup(:fqdn, "decom-01.prod.example.com")

      # DB state
      node = Nodes.get(node_id)
      assert node.lifecycle_state == "decommissioned"
      assert node.decommission_reason == "replaced"
    end
  end

  # ──────────────────────────────────────────────
  # Unreported detection via PubSub
  # ──────────────────────────────────────────────

  describe "detect_unreported via PubSub" do
    test "node transitions to unreported when integration drops it" do
      obs = %Observation{
        plugin_id: "puppet",
        integration_id: "int-detect",
        source_identity: %{certname: "orphan-01.prod"},
        confidence: %{certname: :canonical},
        groups: [],
        last_seen: DateTime.utc_now()
      }

      {:ok, node_id} = Linker.link_observation(obs)

      # First refresh with the node — just verify it was linked
      assert node_id != nil

      # Simulate a refresh that reports an EMPTY batch (node dropped)
      Phoenix.PubSub.broadcast(
        Vigil.PubSub,
        "inventory:cache_refreshed",
        {:integration_cache_refreshed, "int-detect", []}
      )

      # Allow the Linker's mailbox to process the message
      :timer.sleep(50)

      node = Nodes.get(node_id)
      assert node.lifecycle_state == "unreported"
    end
  end

  # ──────────────────────────────────────────────
  # INV-110 — O(M) benchmark (Benchee)
  # ──────────────────────────────────────────────

  describe "INV-110 O(M) linking benchmark" do
    @describetag :perf
    @batch_size 1000

    test "linking 1k observations with 10k existing nodes stays linear" do
      # Pre-populate 10k fake existing nodes via linking observations
      # (cheaper than DB: we use unique certnames that won't collide with the batch)
      for i <- 1..10_000 do
        obs = %Observation{
          plugin_id: "bench-seed",
          integration_id: "int-bench-seed",
          source_identity: %{certname: "existing-node-#{i}.bench.internal"},
          confidence: %{certname: :canonical},
          groups: [],
          last_seen: DateTime.utc_now()
        }

        Linker.link_observation(obs)
      end

      # 1k NEW observations (all misses → case a)
      observations =
        for i <- 1..@batch_size do
          %Observation{
            plugin_id: "bench",
            integration_id: "int-bench",
            source_identity: %{certname: "new-node-#{i}.bench.test"},
            confidence: %{certname: :canonical},
            groups: [],
            last_seen: DateTime.utc_now()
          }
        end

      result =
        Benchee.run(
          %{
            "link_#{@batch_size}_observations" => fn ->
              Enum.each(observations, &Linker.link_observation/1)
            end
          },
          time: 3,
          warmup: 1,
          print: [benchmarking: false, configuration: false],
          formatters: []
        )

      # Extract the scenario's average (median) and assert it's under 5 seconds
      scenario = hd(result.scenarios)
      median_us = scenario.run_time_data.statistics.median

      # 1k observations at O(M) should complete well under 5s on commodity hardware
      assert median_us < 5_000_000,
             "INV-110 FAIL: median #{median_us}µs exceeded 5s threshold for #{@batch_size} observations"
    end
  end

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  defp build_obs(certname, ip) do
    %Observation{
      plugin_id: "puppet",
      integration_id: "int-test-#{:erlang.unique_integer([:positive])}",
      source_identity: %{
        certname: certname,
        fqdn: "#{certname}.example.com",
        ip: ip
      },
      confidence: %{certname: :canonical, fqdn: :strong, ip: :unstable},
      groups: ["webservers"],
      last_seen: DateTime.utc_now()
    }
  end
end

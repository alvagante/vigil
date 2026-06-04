defmodule Vigil.Integrations.BoltTest do
  use ExUnit.Case, async: false

  alias Vigil.Integrations.Bolt
  alias Vigil.Integrations.Bolt.{FakeCLI, Server}
  alias Vigil.Plugin.{Catalog, Conformance, Error, Node, Result, Source}

  @test_config %{
    "project_dir" => "/tmp/bolt_test_project",
    "cli_module" => FakeCLI
  }

  setup %{test: test} do
    agent = FakeCLI.new()
    id = "bolt-#{:erlang.phash2(test)}-#{System.unique_integer([:positive])}"
    config = Map.put(@test_config, "cli_opts", agent: agent)
    {:ok, id: id, config: config, agent: agent}
  end

  defp start_instance(id, config) do
    start_supervised!(Supervisor.child_spec(Bolt.child_spec({id, config}), id: {:bolt, id}))
  end

  # ──────────────────────────────────────────────
  # Tracer 1: lifecycle / conformance
  # ──────────────────────────────────────────────

  describe "lifecycle" do
    test "all Vigil.Plugin callbacks are implemented" do
      assert function_exported?(Bolt, :plugin_id, 0)
      assert function_exported?(Bolt, :display_name, 0)
      assert function_exported?(Bolt, :contract_version, 0)
      assert function_exported?(Bolt, :capabilities, 0)
      assert function_exported?(Bolt, :config_schema, 0)
      assert function_exported?(Bolt, :child_spec, 1)
      assert function_exported?(Bolt, :defaults, 0)
      assert function_exported?(Bolt, :operational_permissions, 0)
    end

    test "plugin_id is 'bolt'" do
      assert Bolt.plugin_id() == "bolt"
    end

    test "conformance lifecycle checks pass", %{config: config} do
      report = Conformance.run(Bolt, config)
      lifecycle_failed = Enum.filter(report.failed, &String.starts_with?(&1.name, "lifecycle:"))

      assert lifecycle_failed == [],
             "lifecycle checks failed:\n" <> Enum.map_join(lifecycle_failed, "\n", & &1.message)
    end

    test "Catalog discovers the Bolt plugin from its OTP app env" do
      assert {:ok, Bolt} = Catalog.lookup("bolt")
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 2: Server config holding
  # ──────────────────────────────────────────────

  describe "Server" do
    test "holds config and returns it via get_config", %{id: id, config: config} do
      start_instance(id, config)
      assert {:ok, ^config} = Server.get_config(id)
    end

    test "returns {:error, :not_found} for unknown integration_id" do
      assert {:error, :not_found} = Server.get_config("no-such-bolt-integration")
    end

    test "supports concurrent slot tracking", %{id: id, config: config} do
      config = Map.put(config, "concurrency", 2)
      start_instance(id, config)

      assert :ok = Server.acquire_slot(id, 2)
      assert :ok = Server.acquire_slot(id, 2)
      assert {:error, :at_capacity} = Server.acquire_slot(id, 2)

      Server.release_slot(id)
      assert :ok = Server.acquire_slot(id, 2)
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 3: list_nodes
  # ──────────────────────────────────────────────

  describe "list_nodes/2 (BOLT-101)" do
    test "returns empty list when bolt reports no targets", %{
      id: id,
      config: config,
      agent: agent
    } do
      FakeCLI.set_inventory(agent, %{"targets" => []})
      start_instance(id, config)

      assert {:ok, %Result{data: [], source: %Source{plugin_id: "bolt", integration_id: ^id}}} =
               Bolt.list_nodes(id, %{})
    end

    test "maps bolt targets to Plugin.Node structs with source attribution",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_inventory(agent, %{
        "targets" => [
          %{
            "name" => "web-01.example.com",
            "uri" => "ssh://web-01.example.com",
            "config" => %{
              "transport" => "ssh",
              "ssh" => %{"host" => "web-01.example.com", "port" => 22}
            },
            "groups" => ["all", "web"],
            "vars" => %{},
            "features" => []
          },
          %{
            "name" => "db-01.example.com",
            "uri" => "ssh://db-01.example.com",
            "config" => %{"transport" => "ssh", "ssh" => %{"host" => "db-01.example.com"}},
            "groups" => ["all", "db"],
            "vars" => %{},
            "features" => []
          }
        ]
      })

      start_instance(id, config)
      assert {:ok, %Result{data: nodes}} = Bolt.list_nodes(id, %{})
      assert length(nodes) == 2
      names = Enum.map(nodes, & &1.name)
      assert "web-01.example.com" in names
      assert "db-01.example.com" in names
    end

    test "nodes carry correct source attribution", %{id: id, config: config, agent: agent} do
      FakeCLI.set_inventory(agent, %{
        "targets" => [
          %{
            "name" => "node1",
            "uri" => "node1",
            "config" => %{},
            "groups" => ["all"],
            "vars" => %{},
            "features" => []
          }
        ]
      })

      start_instance(id, config)

      assert {:ok, %Result{source: %Source{plugin_id: "bolt", integration_id: ^id}}} =
               Bolt.list_nodes(id, %{})
    end

    test "passes --detail flag to bolt inventory show (regression for BOLT-106)", %{
      id: id,
      config: config,
      agent: agent
    } do
      start_instance(id, config)
      Bolt.list_nodes(id, %{})
      assert "--detail" in FakeCLI.last_args(agent)
    end

    test "returns {:error, :not_found} for unknown integration_id" do
      assert {:error, %Error{category: :configuration}} = Bolt.list_nodes("no-such-bolt", %{})
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 4: group structure (BOLT-102)
  # ──────────────────────────────────────────────

  describe "list_nodes/2 group structure (BOLT-102)" do
    test "node attributes include group membership", %{id: id, config: config, agent: agent} do
      FakeCLI.set_inventory(agent, %{
        "targets" => [
          %{
            "name" => "node1",
            "uri" => "node1",
            "config" => %{},
            "groups" => ["all", "linux", "web_servers"],
            "vars" => %{},
            "features" => []
          }
        ]
      })

      start_instance(id, config)
      assert {:ok, %Result{data: [%Node{attributes: attrs}]}} = Bolt.list_nodes(id, %{})
      assert attrs["groups"] == ["all", "linux", "web_servers"]
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 5: transport config + secret redaction (BOLT-103, BOLT-104)
  # ──────────────────────────────────────────────

  describe "list_nodes/2 transport config (BOLT-103, BOLT-104)" do
    test "transport type is preserved in node attributes", %{id: id, config: config, agent: agent} do
      FakeCLI.set_inventory(agent, %{
        "targets" => [
          %{
            "name" => "win-01",
            "uri" => "win-01",
            "config" => %{
              "transport" => "winrm",
              "winrm" => %{"host" => "win-01", "port" => 5986}
            },
            "groups" => ["all"],
            "vars" => %{},
            "features" => []
          }
        ]
      })

      start_instance(id, config)
      assert {:ok, %Result{data: [%Node{attributes: attrs}]}} = Bolt.list_nodes(id, %{})
      assert attrs["transport"] == "winrm"
      assert attrs["transport_config"]["port"] == 5986
    end

    test "password fields are redacted in transport config", %{
      id: id,
      config: config,
      agent: agent
    } do
      FakeCLI.set_inventory(agent, %{
        "targets" => [
          %{
            "name" => "node1",
            "uri" => "node1",
            "config" => %{
              "transport" => "ssh",
              "ssh" => %{"host" => "node1", "user" => "admin", "password" => "s3cr3t"}
            },
            "groups" => ["all"],
            "vars" => %{},
            "features" => []
          }
        ]
      })

      start_instance(id, config)
      assert {:ok, %Result{data: [%Node{attributes: attrs}]}} = Bolt.list_nodes(id, %{})
      assert attrs["transport_config"]["user"] == "admin"
      assert attrs["transport_config"]["password"] == "[REDACTED]"
    end

    test "non-secret fields are preserved", %{id: id, config: config, agent: agent} do
      FakeCLI.set_inventory(agent, %{
        "targets" => [
          %{
            "name" => "node1",
            "uri" => "ssh://node1:2222",
            "config" => %{
              "transport" => "ssh",
              "ssh" => %{"host" => "node1", "port" => 2222, "user" => "deploy"}
            },
            "groups" => ["all"],
            "vars" => %{},
            "features" => []
          }
        ]
      })

      start_instance(id, config)
      assert {:ok, %Result{data: [%Node{attributes: attrs}]}} = Bolt.list_nodes(id, %{})
      assert attrs["transport_config"]["port"] == 2222
      assert attrs["transport_config"]["user"] == "deploy"
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 6: bolt binary not found (BOLT-302)
  # ──────────────────────────────────────────────

  describe "list_nodes/2 error handling" do
    test "returns structured error when bolt executable is missing",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_error(agent, :not_found)
      start_instance(id, config)

      assert {:error, %Error{category: :configuration}} = Bolt.list_nodes(id, %{})
    end

    test "returns transient error on unexpected CLI failure",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_error(agent, :econnrefused)
      start_instance(id, config)

      assert {:error, %Error{category: :transient_external, retriable?: true}} =
               Bolt.list_nodes(id, %{})
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 7: health_check
  # ──────────────────────────────────────────────

  describe "health_check/1" do
    test "returns :healthy when bolt inventory succeeds", %{id: id, config: config} do
      start_instance(id, config)
      assert {:ok, :healthy} = Bolt.health_check(id)
    end

    test "returns :unhealthy when bolt executable is not found",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_error(agent, :not_found)
      start_instance(id, config)
      assert {:ok, :unhealthy} = Bolt.health_check(id)
    end

    test "returns :unhealthy when bolt CLI fails",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_error(agent, :econnrefused)
      start_instance(id, config)
      assert {:ok, :unhealthy} = Bolt.health_check(id)
    end

    test "returns :unhealthy for unknown integration_id" do
      assert {:ok, :unhealthy} = Bolt.health_check("no-such-bolt")
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 8: execution runner (BOLT-201, BOLT-205)
  # ──────────────────────────────────────────────

  describe "Runner / start/4 (BOLT-201, BOLT-205)" do
    test "delivers runner_chunk and runner_target_done per target, then runner_done",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_command_result(agent, %{
        "items" => [
          %{
            "target" => "web-01",
            "action" => "command",
            "object" => "echo hello",
            "status" => "success",
            "value" => %{"stdout" => "hello\n", "stderr" => "", "exit_code" => 0}
          }
        ]
      })

      start_instance(id, config)

      targets = [%{node_id: "web-01", execution_id: "exec-1"}]
      {:ok, pid} = Bolt.start(id, %{text: "echo hello"}, targets, %{stream_pid: self()})
      ref = Process.monitor(pid)

      assert_receive {:runner_chunk, "exec-1", :text, "hello\n"}, 1000
      assert_receive {:runner_target_done, "exec-1", %{exit_status: 0}}, 1000
      assert_receive {:runner_done, %{}}, 1000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    end

    test "handles multiple targets", %{id: id, config: config, agent: agent} do
      FakeCLI.set_command_result(agent, %{
        "items" => [
          %{
            "target" => "node1",
            "status" => "success",
            "value" => %{"stdout" => "out1\n", "stderr" => "", "exit_code" => 0}
          },
          %{
            "target" => "node2",
            "status" => "success",
            "value" => %{"stdout" => "out2\n", "stderr" => "", "exit_code" => 0}
          }
        ]
      })

      start_instance(id, config)

      targets = [
        %{node_id: "node1", execution_id: "exec-a"},
        %{node_id: "node2", execution_id: "exec-b"}
      ]

      Bolt.start(id, %{text: "echo hi"}, targets, %{stream_pid: self()})

      assert_receive {:runner_chunk, "exec-a", :text, _}, 1000
      assert_receive {:runner_target_done, "exec-a", %{exit_status: 0}}, 1000
      assert_receive {:runner_chunk, "exec-b", :text, _}, 1000
      assert_receive {:runner_target_done, "exec-b", %{exit_status: 0}}, 1000
      assert_receive {:runner_done, %{}}, 1000
    end

    test "delivers error chunk when bolt executable missing",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_error(agent, :not_found)
      start_instance(id, config)

      targets = [%{node_id: "web-01", execution_id: "exec-1"}]
      Bolt.start(id, %{text: "echo hi"}, targets, %{stream_pid: self()})

      assert_receive {:runner_chunk, "exec-1", :text, msg}, 1000
      assert String.contains?(msg, "not found") or String.contains?(msg, "bolt")
      assert_receive {:runner_target_done, "exec-1", %{exit_status: -1}}, 1000
      assert_receive {:runner_done, %{error: :bolt_not_found}}, 1000
    end

    test "abort/1 kills the runner process", %{id: id, config: config, agent: agent} do
      FakeCLI.set_command_result(agent, %{"items" => []})
      start_instance(id, config)

      targets = [%{node_id: "node1", execution_id: "exec-1"}]
      {:ok, pid} = Bolt.start(id, %{text: "echo hi"}, targets, %{stream_pid: self()})

      Bolt.abort(pid)
      refute Process.alive?(pid)
    end

    test "returns {:error, :not_found} for unknown integration_id" do
      targets = [%{node_id: "node1", execution_id: "exec-1"}]
      assert {:error, :not_found} = Bolt.start("no-such-bolt", %{text: "echo hi"}, targets, %{})
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 9: concurrency limit (BOLT-303)
  # ──────────────────────────────────────────────

  describe "Runner concurrency limit (BOLT-303)" do
    test "rejects execution when over the configured concurrency limit",
         %{id: id, config: config} do
      config = Map.put(config, "concurrency", 1)
      start_instance(id, config)

      targets = [%{node_id: "node1", execution_id: "exec-1"}]
      assert :ok = Server.acquire_slot(id, 1)

      assert {:error, :at_capacity} = Bolt.start(id, %{text: "echo hi"}, targets, %{})

      Server.release_slot(id)
      assert {:ok, _pid} = Bolt.start(id, %{text: "echo hi"}, targets, %{})
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 10: full conformance suite
  # ──────────────────────────────────────────────

  describe "full conformance suite" do
    test "the Bolt plugin passes all conformance checks", %{id: id, config: config} do
      start_instance(id, config)
      report = Conformance.run(Bolt, config)

      assert Conformance.Report.ok?(report),
             "conformance failures:\n" <>
               Enum.map_join(report.failed, "\n", & &1.message)
    end
  end
end

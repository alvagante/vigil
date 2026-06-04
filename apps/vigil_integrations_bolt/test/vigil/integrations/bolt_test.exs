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
  # Tracer 10: list_tasks/2 (BOLT-202)
  # ──────────────────────────────────────────────

  describe "list_tasks/2 (BOLT-202)" do
    test "returns empty list when bolt reports no tasks", %{id: id, config: config, agent: agent} do
      FakeCLI.set_task_list(agent, %{"tasks" => [], "modulepath" => []})
      start_instance(id, config)
      {:ok, %{data: tasks}} = Bolt.list_tasks(id, %{})
      assert tasks == []
    end

    test "maps bolt tasks to BoltTask structs with name and description",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_task_list(agent, %{
        "tasks" => [["package", "Manage packages"], ["service", nil]],
        "modulepath" => []
      })

      start_instance(id, config)
      {:ok, %{data: tasks}} = Bolt.list_tasks(id, %{})

      assert length(tasks) == 2
      pkg = Enum.find(tasks, &(&1.name == "package"))
      svc = Enum.find(tasks, &(&1.name == "service"))
      assert pkg.description == "Manage packages"
      assert svc.description == nil
    end

    test "passes correct args to bolt CLI (task show --format json)",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_task_list(agent, %{"tasks" => [], "modulepath" => []})
      start_instance(id, config)
      Bolt.list_tasks(id, %{})
      args = FakeCLI.last_args(agent)
      assert args == ["task", "show", "--project", "/tmp/bolt_test_project", "--format", "json"]
    end

    test "returns structured error when bolt executable is missing",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_error(agent, :not_found)
      start_instance(id, config)
      {:error, %{category: :configuration}} = Bolt.list_tasks(id, %{})
    end

    test "returns {:error, :not_found} for unknown integration_id" do
      {:error, %{category: :configuration}} = Bolt.list_tasks("no-such-id", %{})
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 11: show_task/3 (BOLT-202 parameter metadata)
  # ──────────────────────────────────────────────

  describe "show_task/3 (BOLT-202)" do
    setup %{agent: agent} do
      FakeCLI.set_task_detail(agent, %{
        "name" => "package",
        "metadata" => %{
          "description" => "Manage packages",
          "parameters" => %{
            "action" => %{
              "description" => "The operation to perform.",
              "type" => "Enum[install, status, uninstall, upgrade]"
            },
            "name" => %{
              "description" => "The package name.",
              "type" => "String[1]"
            },
            "version" => %{
              "description" => "Optional version.",
              "type" => "Optional[String[1]]"
            }
          }
        }
      })

      :ok
    end

    test "returns BoltTask with parameters", %{id: id, config: config} do
      start_instance(id, config)
      {:ok, %{data: task}} = Bolt.show_task(id, "package", %{})
      assert task.name == "package"
      assert task.description == "Manage packages"
      assert length(task.parameters) == 3
    end

    test "required flag derives from Optional wrapper", %{id: id, config: config} do
      start_instance(id, config)
      {:ok, %{data: task}} = Bolt.show_task(id, "package", %{})
      action = Enum.find(task.parameters, &(&1.name == "action"))
      version = Enum.find(task.parameters, &(&1.name == "version"))
      assert action.required == true
      assert version.required == false
    end

    test "passes task name as third CLI arg", %{id: id, config: config, agent: agent} do
      start_instance(id, config)
      Bolt.show_task(id, "package", %{})
      args = FakeCLI.last_args(agent)
      assert args == ["task", "show", "package", "--project", "/tmp/bolt_test_project", "--format", "json"]
    end

    test "returns {:error, :not_found} for unknown integration_id" do
      {:error, %{category: :configuration}} = Bolt.show_task("no-such-id", "package", %{})
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 12: list_plans/2 + show_plan/3 (BOLT-204)
  # ──────────────────────────────────────────────

  describe "list_plans/2 (BOLT-204)" do
    test "returns empty list when bolt reports no plans", %{id: id, config: config, agent: agent} do
      FakeCLI.set_plan_list(agent, %{"plans" => [], "modulepath" => []})
      start_instance(id, config)
      {:ok, %{data: plans}} = Bolt.list_plans(id, %{})
      assert plans == []
    end

    test "maps bolt plans to BoltPlan structs", %{id: id, config: config, agent: agent} do
      FakeCLI.set_plan_list(agent, %{
        "plans" => [["reboot", "Reboots targets"], ["facts", nil]],
        "modulepath" => []
      })

      start_instance(id, config)
      {:ok, %{data: plans}} = Bolt.list_plans(id, %{})
      assert length(plans) == 2
      reboot = Enum.find(plans, &(&1.name == "reboot"))
      assert reboot.description == "Reboots targets"
    end

    test "passes correct args to bolt CLI (plan show --format json)",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_plan_list(agent, %{"plans" => [], "modulepath" => []})
      start_instance(id, config)
      Bolt.list_plans(id, %{})
      args = FakeCLI.last_args(agent)
      assert args == ["plan", "show", "--project", "/tmp/bolt_test_project", "--format", "json"]
    end

    test "returns {:error, :not_found} for unknown integration_id" do
      {:error, %{category: :configuration}} = Bolt.list_plans("no-such-id", %{})
    end
  end

  describe "show_plan/3 (BOLT-204)" do
    setup %{agent: agent} do
      FakeCLI.set_plan_detail(agent, %{
        "name" => "reboot",
        "description" => "Reboots targets and waits for them to be available again.",
        "parameters" => %{
          "targets" => %{
            "type" => "TargetSpec",
            "sensitive" => false,
            "description" => "Targets to reboot."
          },
          "message" => %{
            "type" => "Optional[String]",
            "sensitive" => false,
            "default_value" => "undef",
            "description" => "Message to log."
          },
          "reboot_delay" => %{
            "type" => "Integer[1]",
            "sensitive" => false,
            "default_value" => "1",
            "description" => "Seconds before rebooting."
          }
        }
      })

      :ok
    end

    test "returns BoltPlan with parameters", %{id: id, config: config} do
      start_instance(id, config)
      {:ok, %{data: plan}} = Bolt.show_plan(id, "reboot", %{})
      assert plan.name == "reboot"
      assert String.contains?(plan.description, "Reboots")
      assert length(plan.parameters) == 3
    end

    test "required flag derives from Optional wrapper in plan params",
         %{id: id, config: config} do
      start_instance(id, config)
      {:ok, %{data: plan}} = Bolt.show_plan(id, "reboot", %{})
      targets_param = Enum.find(plan.parameters, &(&1.name == "targets"))
      message_param = Enum.find(plan.parameters, &(&1.name == "message"))
      assert targets_param.required == true
      assert message_param.required == false
    end

    test "sensitive flag is preserved from plan param metadata",
         %{id: id, config: config} do
      start_instance(id, config)
      {:ok, %{data: plan}} = Bolt.show_plan(id, "reboot", %{})
      delay_param = Enum.find(plan.parameters, &(&1.name == "reboot_delay"))
      assert delay_param.sensitive == false
    end

    test "passes plan name as third CLI arg", %{id: id, config: config, agent: agent} do
      start_instance(id, config)
      Bolt.show_plan(id, "reboot", %{})
      args = FakeCLI.last_args(agent)
      assert args == ["plan", "show", "reboot", "--project", "/tmp/bolt_test_project", "--format", "json"]
    end

    test "returns {:error, :not_found} for unknown integration_id" do
      {:error, %{category: :configuration}} = Bolt.show_plan("no-such-id", "reboot", %{})
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 13: task execution via Runner (BOLT-202)
  # ──────────────────────────────────────────────

  describe "Runner task execution (BOLT-202)" do
    test "executes bolt task run and delivers results per target",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_task_run_result(agent, %{
        "items" => [
          %{"target" => "web-01", "action" => "task", "object" => "package",
            "status" => "success", "value" => %{"status" => "installed", "version" => "1.2.3"}}
        ]
      })

      start_instance(id, config)
      stream_pid = self()

      target = %{execution_id: "exec-1", node_id: "web-01"}
      artifact = %{kind: :task, name: "package", params: %{"action" => "install", "name" => "nginx"}}

      {:ok, _pid} = Bolt.start(id, artifact, [target], %{stream_pid: stream_pid})

      assert_receive {:runner_chunk, "exec-1", :text, text}, 2000
      assert String.contains?(text, "installed") or String.contains?(text, "1.2.3")
      assert_receive {:runner_target_done, "exec-1", %{exit_status: 0}}, 2000
      assert_receive {:runner_done, %{}}, 2000
    end

    test "passes task name and JSON params to CLI",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_task_run_result(agent, %{"items" => []})
      start_instance(id, config)

      target = %{execution_id: "exec-1", node_id: "web-01"}
      artifact = %{kind: :task, name: "package", params: %{"action" => "status", "name" => "nginx"}}

      {:ok, pid} = Bolt.start(id, artifact, [target], %{stream_pid: self()})
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 3000

      args = FakeCLI.last_args(agent)
      assert Enum.take(args, 3) == ["task", "run", "package"]
      assert "--params" in args
      params_json = Enum.at(args, Enum.find_index(args, &(&1 == "--params")) + 1)
      decoded = Jason.decode!(params_json)
      assert decoded["action"] == "status"
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 14: plan execution via Runner (BOLT-204)
  # ──────────────────────────────────────────────

  describe "Runner plan execution (BOLT-204)" do
    test "executes bolt plan run and delivers result to synthetic __plan__ target",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_plan_run_result(agent, %{"targets_ran" => 3, "status" => "success"})
      start_instance(id, config)

      target = %{execution_id: "plan-exec-1", node_id: "__plan__"}
      artifact = %{kind: :plan, name: "reboot", params: %{"targets" => "web-01,web-02,web-03"}}

      {:ok, _pid} = Bolt.start(id, artifact, [target], %{stream_pid: self()})

      assert_receive {:runner_chunk, "plan-exec-1", :text, text}, 2000
      assert String.contains?(text, "success") or String.contains?(text, "targets_ran")
      assert_receive {:runner_target_done, "plan-exec-1", %{exit_status: 0}}, 2000
      assert_receive {:runner_done, %{}}, 2000
    end

    test "passes plan name and JSON params to CLI (no --targets flag)",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_plan_run_result(agent, %{"result" => "ok"})
      start_instance(id, config)

      target = %{execution_id: "plan-exec-2", node_id: "__plan__"}
      artifact = %{kind: :plan, name: "facts", params: %{"targets" => "db-01"}}

      {:ok, pid} = Bolt.start(id, artifact, [target], %{stream_pid: self()})
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 3000

      args = FakeCLI.last_args(agent)
      assert Enum.take(args, 3) == ["plan", "run", "facts"]
      assert "--params" in args
      refute "--targets" in args
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 15: full conformance suite
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

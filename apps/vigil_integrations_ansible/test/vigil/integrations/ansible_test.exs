defmodule Vigil.Integrations.AnsibleTest do
  use ExUnit.Case, async: false

  alias Vigil.Integrations.Ansible
  alias Vigil.Integrations.Ansible.{FakeCLI, Server}
  alias Vigil.Plugin.{Catalog, Conformance, Error, Result}

  @test_config %{
    "cli_module" => FakeCLI
  }

  setup %{test: test} do
    agent = FakeCLI.new()
    id = "ansible-#{:erlang.phash2(test)}-#{System.unique_integer([:positive])}"
    config = Map.put(@test_config, "cli_opts", agent: agent)
    {:ok, id: id, config: config, agent: agent}
  end

  defp start_instance(id, config) do
    start_supervised!(Supervisor.child_spec(Ansible.child_spec({id, config}), id: {:ansible, id}))
  end

  # ──────────────────────────────────────────────
  # Tracer 1: lifecycle / conformance
  # ──────────────────────────────────────────────

  describe "lifecycle" do
    test "all Vigil.Plugin callbacks are implemented" do
      assert function_exported?(Ansible, :plugin_id, 0)
      assert function_exported?(Ansible, :display_name, 0)
      assert function_exported?(Ansible, :contract_version, 0)
      assert function_exported?(Ansible, :capabilities, 0)
      assert function_exported?(Ansible, :config_schema, 0)
      assert function_exported?(Ansible, :child_spec, 1)
      assert function_exported?(Ansible, :defaults, 0)
      assert function_exported?(Ansible, :operational_permissions, 0)
    end

    test "plugin_id is 'ansible'" do
      assert Ansible.plugin_id() == "ansible"
    end

    test "capabilities include inventory, facts, and execution" do
      assert :inventory in Ansible.capabilities()
      assert :facts in Ansible.capabilities()
      assert :execution in Ansible.capabilities()
    end

    test "conformance lifecycle checks pass", %{config: config} do
      report = Conformance.run(Ansible, config)
      lifecycle_failed = Enum.filter(report.failed, &String.starts_with?(&1.name, "lifecycle:"))

      assert lifecycle_failed == [],
             "lifecycle checks failed:\n" <> Enum.map_join(lifecycle_failed, "\n", & &1.message)
    end

    test "Catalog discovers the Ansible plugin from its OTP app env" do
      assert {:ok, Ansible} = Catalog.lookup("ansible")
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
      assert {:error, :not_found} = Server.get_config("no-such-ansible-integration")
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
  # Tracer 3: list_nodes / inventory parsing (ANS-INV-*)
  # ──────────────────────────────────────────────

  describe "list_nodes/2 (ANS-INV-*)" do
    test "returns nodes from ansible-inventory --list output",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_inventory(agent, %{
        "_meta" => %{
          "hostvars" => %{
            "web-01.example.com" => %{"ansible_host" => "10.0.0.1"},
            "db-01.example.com" => %{"ansible_host" => "10.0.0.2"}
          }
        },
        "all" => %{"children" => ["webservers", "ungrouped"]},
        "webservers" => %{"hosts" => ["web-01.example.com"]},
        "ungrouped" => %{"hosts" => ["db-01.example.com"]}
      })

      start_instance(id, config)

      assert {:ok, %Result{data: nodes}} = Ansible.list_nodes(id, %{})
      assert length(nodes) == 2
      names = Enum.map(nodes, & &1.name)
      assert "web-01.example.com" in names
      assert "db-01.example.com" in names
    end

    test "captures primary_ip from ansible_host variable",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_inventory(agent, %{
        "_meta" => %{
          "hostvars" => %{
            "host1" => %{"ansible_host" => "192.168.1.100"}
          }
        },
        "all" => %{"children" => ["ungrouped"]},
        "ungrouped" => %{"hosts" => ["host1"]}
      })

      start_instance(id, config)

      assert {:ok, %Result{data: [node]}} = Ansible.list_nodes(id, %{})
      assert node.attributes["primary_ip"] == "192.168.1.100"
    end

    test "captures group membership for each node",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_inventory(agent, %{
        "_meta" => %{
          "hostvars" => %{
            "web-01" => %{}
          }
        },
        "all" => %{"children" => ["production"]},
        "production" => %{"hosts" => ["web-01"]},
        "web" => %{"hosts" => ["web-01"]}
      })

      start_instance(id, config)

      assert {:ok, %Result{data: [node]}} = Ansible.list_nodes(id, %{})
      assert "production" in node.attributes["groups"]
      assert "web" in node.attributes["groups"]
    end

    test "returns empty list when inventory has no hosts",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_inventory(agent, %{
        "_meta" => %{"hostvars" => %{}},
        "all" => %{"children" => ["ungrouped"]},
        "ungrouped" => %{"hosts" => []}
      })

      start_instance(id, config)

      assert {:ok, %Result{data: []}} = Ansible.list_nodes(id, %{})
    end

    test "result has correct source attribution",
         %{id: id, config: config} do
      start_instance(id, config)

      assert {:ok, %Result{source: source}} = Ansible.list_nodes(id, %{})
      assert source.plugin_id == "ansible"
      assert source.integration_id == id
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 4: inventory edge cases (ANS-107)
  # ──────────────────────────────────────────────

  describe "list_nodes/2 edge cases (ANS-107)" do
    test "returns transient_external error on timeout",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_error(agent, :timeout)
      start_instance(id, config)

      assert {:error, %Error{category: :transient_external}} = Ansible.list_nodes(id, %{})
    end

    test "returns configuration error when executable not found",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_error(agent, :not_found)
      start_instance(id, config)

      assert {:error, %Error{category: :configuration}} = Ansible.list_nodes(id, %{})
    end

    test "returns configuration error on malformed error signal",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_error(agent, :malformed)
      start_instance(id, config)

      assert {:error, %Error{category: :configuration}} = Ansible.list_nodes(id, %{})
    end

    test "returns configuration error for unknown integration id" do
      assert {:error, %Error{category: :configuration}} =
               Ansible.list_nodes("no-such-ansible", %{})
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 5: get_facts / setup module (ANS-FACT-*)
  # ──────────────────────────────────────────────

  describe "get_facts/2 (ANS-FACT-*)" do
    test "returns normalized and raw facts for a node",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_facts(agent, %{
        "web-01" => %{
          "ansible_facts" => %{
            "ansible_distribution" => "Ubuntu",
            "ansible_distribution_version" => "22.04",
            "ansible_kernel" => "5.15.0-91-generic",
            "ansible_hostname" => "web-01",
            "ansible_fqdn" => "web-01.example.com",
            "ansible_all_ipv4_addresses" => ["10.0.0.1"],
            "ansible_processor_vcpus" => 4,
            "ansible_memtotal_mb" => 8192
          },
          "changed" => false
        }
      })

      start_instance(id, config)

      assert {:ok, %Result{data: facts}} = Ansible.get_facts(id, %{node: "web-01"})
      assert facts.normalized["os.distribution"] == "Ubuntu"
      assert facts.normalized["cpu.count"] == 4
      assert facts.normalized["memory.total_mb"] == 8192
      assert facts.raw["ansible_distribution"] == "Ubuntu"
    end

    test "returns configuration error for unknown integration id" do
      assert {:error, %Error{category: :configuration}} =
               Ansible.get_facts("no-such-ansible", %{node: "host1"})
    end

    test "returns transient_external error on CLI timeout",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_error(agent, :timeout)
      start_instance(id, config)

      assert {:error, %Error{category: :transient_external}} =
               Ansible.get_facts(id, %{node: "host1"})
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 6: execution runner — ad-hoc (ANS-401)
  # ──────────────────────────────────────────────

  describe "start/4 ad-hoc execution (ANS-401)" do
    test "start/4 with zero targets returns {:ok, pid} and sends runner_done",
         %{id: id, config: config} do
      start_instance(id, config)

      assert {:ok, pid} = Ansible.start(id, %{}, [], %{stream_pid: self()})
      assert is_pid(pid)
      assert_receive {:runner_done, %{}}, 1_000
    end

    test "start/4 runs ad-hoc command and delivers runner messages per target",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_command_result(agent, %{"host-01" => %{"stdout" => "pong", "exit_code" => 0}})

      start_instance(id, config)

      targets = [%{node_id: "host-01", execution_id: "exec-1"}]
      artifact = %{kind: :command, module: "ping", text: ""}

      assert {:ok, _pid} = Ansible.start(id, artifact, targets, %{stream_pid: self()})
      assert_receive {:runner_target_done, "exec-1", %{exit_status: 0}}, 2_000
      assert_receive {:runner_done, %{}}, 2_000
    end

    test "abort/1 terminates a running runner process",
         %{id: id, config: config} do
      start_instance(id, config)

      {:ok, pid} = Ansible.start(id, %{}, [], %{stream_pid: self()})
      assert :ok = Ansible.abort(pid)
    end

    test "conformance execution contract passes", %{config: config} do
      report = Conformance.run(Ansible, config)
      exec_failed = Enum.filter(report.failed, &String.starts_with?(&1.name, "execution:"))

      assert exec_failed == [],
             "execution checks failed:\n" <> Enum.map_join(exec_failed, "\n", & &1.message)
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 7: execution runner — playbook (ANS-402, ANS-405)
  # ──────────────────────────────────────────────

  describe "start/4 playbook execution (ANS-402)" do
    test "runs a playbook and delivers per-target runner messages",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_playbook_result(agent, %{
        "play_recap" => %{"host-01" => %{"ok" => 5, "changed" => 2, "failed" => 0}}
      })

      start_instance(id, config)

      targets = [%{node_id: "host-01", execution_id: "exec-pb-1"}]
      artifact = %{kind: :playbook, path: "site.yml"}

      assert {:ok, _pid} = Ansible.start(id, artifact, targets, %{stream_pid: self()})
      assert_receive {:runner_target_done, "exec-pb-1", %{exit_status: 0}}, 2_000
      assert_receive {:runner_done, %{}}, 2_000
    end

    test "passes extra_vars to the playbook invocation",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_playbook_result(agent, %{"ok" => true})

      start_instance(id, config)

      targets = [%{node_id: "host-01", execution_id: "exec-ev-1"}]
      artifact = %{kind: :playbook, path: "deploy.yml", extra_vars: %{env: "staging"}}

      assert {:ok, _pid} = Ansible.start(id, artifact, targets, %{stream_pid: self()})
      assert_receive {:runner_done, %{}}, 2_000

      last = FakeCLI.last_args(agent)
      assert "--extra-vars" in last
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 8: health check (ANS-604)
  # ──────────────────────────────────────────────

  describe "health_check/1 (ANS-604)" do
    test "returns :healthy when ansible --version succeeds",
         %{id: id, config: config} do
      start_instance(id, config)
      assert {:ok, :healthy} = Ansible.health_check(id)
    end

    test "returns :unhealthy when executable not found",
         %{id: id, config: config, agent: agent} do
      FakeCLI.set_error(agent, :not_found)
      start_instance(id, config)
      assert {:ok, :unhealthy} = Ansible.health_check(id)
    end

    test "returns :unhealthy for unknown integration id" do
      assert {:ok, :unhealthy} = Ansible.health_check("no-such-ansible")
    end
  end
end

defmodule Vigil.Integrations.SSHTest do
  use ExUnit.Case, async: false

  alias Vigil.Integrations.SSH
  alias Vigil.Integrations.SSH.FakeTransport
  alias Vigil.Plugin.{Catalog, Conformance, Error, Result, Source}

  @config_body """
  Host web-prod-01
      HostName 10.0.0.1
      Port 2222
      User deploy

  Host *.staging
      User stager
  """

  setup %{test: test} do
    dir = Path.join(System.tmp_dir!(), "ssh-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    config_path = Path.join(dir, "config")
    File.write!(config_path, @config_body)

    agent = FakeTransport.new(%{responses: fact_responses()})
    id = "ssh-#{:erlang.phash2(test)}-#{System.unique_integer([:positive])}"

    config = %{
      "config_file" => config_path,
      "transport" => FakeTransport,
      "transport_opts" => [agent: agent]
    }

    {:ok, id: id, config: config, config_path: config_path, agent: agent, dir: dir}
  end

  defp start_instance(id, config) do
    start_supervised!(Supervisor.child_spec(SSH.child_spec({id, config}), id: {:ssh, id}))
  end

  defp fact_responses do
    %{
      "cat /etc/os-release" => {0, "ID=ubuntu\nNAME=\"Ubuntu\"\nVERSION_ID=\"22.04\"\n", ""},
      "uname -s -r -m" => {0, "Linux 5.15.0 x86_64", ""},
      "nproc" => {0, "8\n", ""}
    }
  end

  describe "discovery (design §3.2.1)" do
    test "the Catalog auto-discovers the SSH plugin from its OTP app env" do
      assert {:ok, SSH} = Catalog.lookup("ssh")
    end
  end

  describe "list_nodes/2 (SSH-101..103, INV-201)" do
    test "parses the config file into source-attributed nodes", %{id: id, config: config} do
      start_instance(id, config)

      assert {:ok, %Result{data: nodes, source: %Source{plugin_id: "ssh", integration_id: ^id}}} =
               SSH.list_nodes(id, %{})

      web = Enum.find(nodes, &(&1.name == "web-prod-01"))
      assert web.attributes["hostname"] == "10.0.0.1"
      assert web.attributes["port"] == 2222
      assert web.targetable?

      staging = Enum.find(nodes, &(&1.name == "*.staging"))
      refute staging.targetable?
    end

    test "treats a missing config file as an empty inventory", %{id: id, config: config} do
      config = Map.put(config, "config_file", "/no/such/ssh/config")
      start_instance(id, config)

      assert {:ok, %Result{data: []}} = SSH.list_nodes(id, %{})
    end
  end

  describe "get_facts/2 (SSH-201, SSH-202)" do
    test "gathers and parses baseline facts for a host", %{id: id, config: config} do
      start_instance(id, config)

      assert {:ok, %Result{data: facts, source: %Source{plugin_id: "ssh"}}} =
               SSH.get_facts(id, %{"node" => "web-prod-01"})

      assert facts["os.distro"] == "ubuntu"
      assert facts["os.version"] == "22.04"
      assert facts["architecture"] == "x86_64"
      assert facts["cpu.count"] == 8
    end

    test "errors for a host not in inventory", %{id: id, config: config} do
      start_instance(id, config)
      assert {:error, %Error{category: :user_input}} = SSH.get_facts(id, %{"node" => "ghost"})
    end

    test "refuses wildcard hosts as non-targetable (SSH-103)", %{id: id, config: config} do
      start_instance(id, config)
      assert {:error, %Error{category: :user_input}} = SSH.get_facts(id, %{"node" => "*.staging"})
    end

    test "reports a structured error when the host is unreachable (ERR-*)", %{config: config} do
      agent = FakeTransport.new(%{connect_error: :econnrefused})
      id = "ssh-unreach-#{System.unique_integer([:positive])}"
      config = Map.put(config, "transport_opts", agent: agent)
      start_instance(id, config)

      assert {:error, %Error{category: :transient_external, retriable?: true}} =
               SSH.get_facts(id, %{"node" => "web-prod-01"})
    end
  end

  describe "health_check/1 (per-host probing)" do
    test "reports :healthy when all targetable hosts are reachable", %{id: id, config: config} do
      start_instance(id, config)
      assert {:ok, :healthy} = SSH.health_check(id)
    end

    test "reports :unhealthy when no host is reachable", %{config: config} do
      agent = FakeTransport.new(%{connect_error: :ehostunreach})
      id = "ssh-down-#{System.unique_integer([:positive])}"
      config = Map.put(config, "transport_opts", agent: agent)
      start_instance(id, config)

      assert {:ok, :unhealthy} = SSH.health_check(id)
    end

    test "reports :unhealthy for an unknown integration (no running instance)" do
      assert {:ok, :unhealthy} = SSH.health_check("never-started")
    end
  end

  describe "conformance (#4 suite)" do
    test "the SSH plugin passes the plugin conformance suite", %{config: config} do
      report = Conformance.run(SSH, config)

      assert Conformance.Report.ok?(report),
             "expected no failures, got:\n" <> Enum.map_join(report.failed, "\n", & &1.message)

      assert Enum.any?(report.passed, &(&1.name == "inventory:list_nodes/2:result_shape"))
      assert Enum.any?(report.passed, &(&1.name == "facts:get_facts/2:result_shape"))
    end
  end
end

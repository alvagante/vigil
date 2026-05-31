defmodule Vigil.Integrations.SSH.FactParserTest do
  use ExUnit.Case, async: true

  alias Vigil.Integrations.SSH.FactParser

  test "parses /etc/os-release into distro and version (SSH-201)" do
    text = """
    NAME="Ubuntu"
    VERSION="22.04.3 LTS (Jammy Jellyfish)"
    ID=ubuntu
    VERSION_ID="22.04"
    PRETTY_NAME="Ubuntu 22.04.3 LTS"
    """

    facts = FactParser.parse_os_release(text)
    assert facts["os.distro"] == "ubuntu"
    assert facts["os.name"] == "Ubuntu"
    assert facts["os.version"] == "22.04"
    assert facts["os.pretty_name"] == "Ubuntu 22.04.3 LTS"
  end

  test "parses `uname -s -r -m` into kernel and architecture (SSH-201)" do
    facts = FactParser.parse_uname("Linux 5.15.0-89-generic x86_64")
    assert facts["kernel.name"] == "Linux"
    assert facts["kernel.release"] == "5.15.0-89-generic"
    assert facts["architecture"] == "x86_64"
  end

  test "parses `ip -j addr` JSON into interfaces with IPs (SSH-201, SSH-202)" do
    json = """
    [
      {"ifname":"lo","addr_info":[{"family":"inet","local":"127.0.0.1"}]},
      {"ifname":"eth0","addr_info":[
        {"family":"inet","local":"10.0.0.5"},
        {"family":"inet6","local":"fe80::1"}
      ]}
    ]
    """

    facts = FactParser.parse_ip_json(json)
    interfaces = facts["network.interfaces"]
    eth0 = Enum.find(interfaces, &(&1["name"] == "eth0"))
    assert "10.0.0.5" in eth0["addresses"]
    assert "fe80::1" in eth0["addresses"]
  end

  test "parse_ip_json tolerates malformed JSON by returning no interface facts" do
    assert FactParser.parse_ip_json("not json") == %{}
  end

  test "parses /proc/meminfo total and nproc into numeric facts" do
    assert FactParser.parse_meminfo("MemTotal:       16336248 kB\nMemFree: 100 kB\n") ==
             %{"memory.total_kb" => 16_336_248}

    assert FactParser.parse_nproc("8\n") == %{"cpu.count" => 8}
  end

  test "merge/1 flattens a map of command outputs into one fact map" do
    outputs = %{
      os_release: "ID=debian\nVERSION_ID=\"12\"\n",
      uname: "Linux 6.1.0 aarch64",
      nproc: "4",
      hostname: "edge-1\n"
    }

    facts = FactParser.merge(outputs)
    assert facts["os.distro"] == "debian"
    assert facts["architecture"] == "aarch64"
    assert facts["cpu.count"] == 4
    assert facts["hostname"] == "edge-1"
  end
end

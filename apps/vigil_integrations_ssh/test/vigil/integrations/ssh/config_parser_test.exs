defmodule Vigil.Integrations.SSH.ConfigParserTest do
  use ExUnit.Case, async: true

  alias Vigil.Integrations.SSH.ConfigParser
  alias Vigil.Plugin.Node

  describe "parse/1" do
    test "parses a Host block into a node with connection attributes (SSH-101, SSH-102)" do
      config = """
      Host web-prod-01
          HostName 10.0.0.1
          Port 2222
          User deploy
          IdentityFile ~/.ssh/id_prod
      """

      assert [%Node{} = node] = ConfigParser.parse(config)
      assert node.name == "web-prod-01"
      assert node.attributes["hostname"] == "10.0.0.1"
      assert node.attributes["port"] == 2222
      assert node.attributes["user"] == "deploy"
      assert node.attributes["identity_file"] == "~/.ssh/id_prod"
      assert node.targetable?
    end

    test "defaults hostname to the alias when HostName is absent (SSH-102 'resolved')" do
      assert [node] = ConfigParser.parse("Host db1\n  User postgres\n")
      assert node.attributes["hostname"] == "db1"
    end

    test "is case-insensitive on keywords and tolerates '=' separators" do
      config = "host app1\n  hostname=192.168.1.5\n  PORT 22\n"
      assert [node] = ConfigParser.parse(config)
      assert node.attributes["hostname"] == "192.168.1.5"
      assert node.attributes["port"] == 22
    end

    test "flags wildcard Host patterns as non-targetable (SSH-103)" do
      config = """
      Host *.staging
          User stager
      Host *
          User defaultuser
      """

      nodes = ConfigParser.parse(config)
      assert Enum.all?(nodes, &(&1.targetable? == false))
      assert "*.staging" in Enum.map(nodes, & &1.name)
    end

    test "expands a multi-alias Host line into one node per alias (SSH-101)" do
      assert nodes = ConfigParser.parse("Host alpha beta\n  User root\n")
      assert Enum.map(nodes, & &1.name) == ["alpha", "beta"]
      assert Enum.all?(nodes, &(&1.attributes["user"] == "root"))
    end

    test "ignores comments and blank lines" do
      config = """
      # a comment
      Host only

         # indented comment
         User x
      """

      assert [node] = ConfigParser.parse(config)
      assert node.name == "only"
    end

    test "returns [] for empty input" do
      assert ConfigParser.parse("") == []
      assert ConfigParser.parse("# only comments\n") == []
    end
  end

  describe "parse_file/1 with Include directives (SSH-104)" do
    @tag :tmp_dir
    test "resolves Include directives relative to the including file", %{tmp_dir: dir} do
      included = Path.join(dir, "extra.conf")
      File.write!(included, "Host included-host\n  HostName 10.9.9.9\n")

      main = Path.join(dir, "config")
      File.write!(main, "Host main-host\n  HostName 10.0.0.1\nInclude #{included}\n")

      assert {:ok, nodes} = ConfigParser.parse_file(main)
      names = Enum.map(nodes, & &1.name)
      assert "main-host" in names
      assert "included-host" in names
    end

    test "returns {:error, ...} for a missing file" do
      assert {:error, _} = ConfigParser.parse_file("/nonexistent/ssh/config")
    end
  end
end

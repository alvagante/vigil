defmodule Vigil.Test.Fixtures.GeneratorTest do
  use ExUnit.Case, async: true

  alias Vigil.Test.Fixtures.Generator

  describe "puppetdb_nodes/1" do
    test "returns valid JSON" do
      json = Generator.puppetdb_nodes(count: 3)
      assert {:ok, nodes} = Jason.decode(json)
      assert is_list(nodes)
    end

    test "returns exactly count nodes" do
      json = Generator.puppetdb_nodes(count: 7)
      {:ok, nodes} = Jason.decode(json)
      assert length(nodes) == 7
    end

    test "nodes_100 produces 100 nodes" do
      json = Generator.puppetdb_nodes(count: 100)
      {:ok, nodes} = Jason.decode(json)
      assert length(nodes) == 100
    end

    test "each node has required PuppetDB fields" do
      json = Generator.puppetdb_nodes(count: 5)
      {:ok, nodes} = Jason.decode(json)

      for node <- nodes do
        assert is_binary(node["certname"]), "certname must be a string"
        assert String.contains?(node["certname"], ".example.com")
        assert node["latest_report_status"] in ["changed", "unchanged", "failed"]
        assert is_binary(node["catalog_timestamp"])
        assert is_boolean(node["latest_report_noop"])
        assert node["cached_catalog_status"] in ["not_used", "used"]
      end
    end

    test "certnames are unique" do
      json = Generator.puppetdb_nodes(count: 50)
      {:ok, nodes} = Jason.decode(json)
      certnames = Enum.map(nodes, & &1["certname"])
      assert length(Enum.uniq(certnames)) == 50
    end

    test "injects ~1% deactivated nodes (TEST-903)" do
      json = Generator.puppetdb_nodes(count: 1_000)
      {:ok, nodes} = Jason.decode(json)
      deactivated = Enum.filter(nodes, fn n -> n["deactivated"] != nil end)
      # 0.5%–2% at 1k
      assert length(deactivated) >= 3
      assert length(deactivated) <= 30
    end

    test "injects ~2% nodes with nil facts_timestamp (TEST-903)" do
      json = Generator.puppetdb_nodes(count: 1_000)
      {:ok, nodes} = Jason.decode(json)
      missing_facts = Enum.filter(nodes, fn n -> n["facts_timestamp"] == nil end)
      # 1%–4% at 1k
      assert length(missing_facts) >= 5
      assert length(missing_facts) <= 50
    end
  end
end

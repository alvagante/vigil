defmodule Vigil.Core.FactsTest do
  use ExUnit.Case, async: true

  alias Vigil.Core.Facts
  alias Vigil.Core.Facts.Row

  @source %{
    plugin_id: "ssh",
    integration_id: "ssh-1",
    integration_name: "lab SSH",
    gathered_at: ~U[2026-05-30 12:00:00Z]
  }

  test "rows_from_source/2 builds one source-attributed row per fact, sorted by key" do
    facts = %{"os.distro" => "ubuntu", "cpu.count" => 8}

    rows = Facts.rows_from_source(facts, @source)

    assert [%Row{key: "cpu.count", value: 8}, %Row{key: "os.distro", value: "ubuntu"}] = rows
    assert Enum.all?(rows, &(&1.sources == [@source]))
  end

  test "rows_from_source/2 returns [] for empty facts" do
    assert Facts.rows_from_source(%{}, @source) == []
  end

  test "rows_from_source/2 renders nested/structured values verbatim in the row" do
    facts = %{"network.interfaces" => [%{"name" => "eth0", "addresses" => ["10.0.0.5"]}]}

    assert [%Row{key: "network.interfaces", value: [%{"name" => "eth0"} | _]}] =
             Facts.rows_from_source(facts, @source)
  end
end

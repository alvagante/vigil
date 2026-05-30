defmodule Vigil.Plugin.ConformanceTest do
  use ExUnit.Case, async: false

  alias Vigil.Plugin.Conformance

  test "the reference no-op plugin passes the conformance suite" do
    report = Conformance.run(Vigil.Plugin.NoOp, %{})

    assert Conformance.Report.ok?(report),
           "expected no failures, got:\n" <> Enum.map_join(report.failed, "\n", & &1.message)

    # The suite must actually exercise the contract, not vacuously pass.
    refute report.passed == []
    assert Enum.any?(report.passed, &(&1.name == "lifecycle:callback:contract_version/0"))
    assert Enum.any?(report.passed, &(&1.name == "inventory:list_nodes/2:result_shape"))
    assert Enum.any?(report.passed, &(&1.name == "execution:start/4:shape"))
  end

  test "a declared capability with no conformance contract surfaces as a warning (ROAD-105)" do
    report = Conformance.run(Vigil.Plugin.ConformanceFake, %{})

    # Warnings do not fail conformance, but the gap must be visible — never a silent pass.
    assert Conformance.Report.ok?(report)
    assert Enum.any?(report.warnings, &(&1.name == "capability:facts:no_contract"))
  end
end

defmodule Vigil.StartupOrderTest do
  @moduledoc """
  Asserts the §2.2.1 startup order: vigil_core → vigil_plugin → vigil_web,
  realized in Option B (distributed application/0) via mix-deps ordering.
  """

  use ExUnit.Case

  test "umbrella boots vigil_core, vigil_plugin, and vigil_web" do
    started = Application.started_applications() |> Enum.map(&elem(&1, 0))
    assert :vigil_core in started
    assert :vigil_plugin in started
    assert :vigil_web in started
  end

  test "vigil_web declares :vigil_core and :vigil_plugin as runtime app dependencies (drives BEAM start order)" do
    {:ok, deps} = :application.get_key(:vigil_web, :applications)
    assert :vigil_core in deps
    assert :vigil_plugin in deps
  end

  test "vigil_plugin declares :vigil_core as a runtime dep (Manager needs Repo + PubSub at startup)" do
    {:ok, deps} = :application.get_key(:vigil_plugin, :applications)
    assert :vigil_core in deps
  end
end

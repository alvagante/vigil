defmodule Vigil.Plugin.LifecycleTest do
  use ExUnit.Case, async: true

  test "a plugin reports health through the Vigil.Plugin.Health hook" do
    assert {:ok, :healthy} = Vigil.Plugin.NoOp.health_check("any-integration")
  end

  test "the no-op plugin declares it implements the Health behaviour" do
    behaviours =
      Vigil.Plugin.NoOp.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert Vigil.Plugin.Health in behaviours
  end
end

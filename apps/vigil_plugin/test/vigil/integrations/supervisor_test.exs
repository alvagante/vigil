defmodule Vigil.Integrations.SupervisorTest do
  use ExUnit.Case

  test "Vigil.Integrations.Supervisor supervises zero children when no integrations are configured (ERR-801)" do
    assert DynamicSupervisor.which_children(Vigil.Integrations.Supervisor) == []
  end
end

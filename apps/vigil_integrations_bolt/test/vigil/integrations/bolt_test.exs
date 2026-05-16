defmodule Vigil.Integrations.BoltTest do
  use ExUnit.Case
  doctest Vigil.Integrations.Bolt

  test "greets the world" do
    assert Vigil.Integrations.Bolt.hello() == :world
  end
end

defmodule Vigil.Integrations.SSHTest do
  use ExUnit.Case
  doctest Vigil.Integrations.SSH

  test "greets the world" do
    assert Vigil.Integrations.SSH.hello() == :world
  end
end

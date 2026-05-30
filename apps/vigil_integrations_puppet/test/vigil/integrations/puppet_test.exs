defmodule Vigil.Integrations.PuppetTest do
  use ExUnit.Case
  doctest Vigil.Integrations.Puppet

  test "greets the world" do
    assert Vigil.Integrations.Puppet.hello() == :world
  end
end

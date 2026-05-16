defmodule Vigil.PluginTest do
  use ExUnit.Case
  doctest Vigil.Plugin

  test "greets the world" do
    assert Vigil.Plugin.hello() == :world
  end
end

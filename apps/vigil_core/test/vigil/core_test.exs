defmodule Vigil.CoreTest do
  use ExUnit.Case
  doctest Vigil.Core

  test "greets the world" do
    assert Vigil.Core.hello() == :world
  end
end

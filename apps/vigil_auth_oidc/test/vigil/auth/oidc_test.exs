defmodule Vigil.Auth.OIDCTest do
  use ExUnit.Case
  doctest Vigil.Auth.OIDC

  test "greets the world" do
    assert Vigil.Auth.OIDC.hello() == :world
  end
end

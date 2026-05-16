defmodule Vigil.Integrations.ProxmoxTest do
  use ExUnit.Case
  doctest Vigil.Integrations.Proxmox

  test "greets the world" do
    assert Vigil.Integrations.Proxmox.hello() == :world
  end
end

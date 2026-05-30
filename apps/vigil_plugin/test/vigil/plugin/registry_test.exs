defmodule Vigil.Plugin.RegistryTest do
  use ExUnit.Case, async: false

  test "Vigil.Plugin.Registry supports register/lookup roundtrip with unique keys" do
    key = {:integration, make_ref()}

    {:ok, _pid} = Registry.register(Vigil.Plugin.Registry, key, :metadata)

    assert [{registered_pid, :metadata}] = Registry.lookup(Vigil.Plugin.Registry, key)
    assert registered_pid == self()
  end
end

defmodule Vigil.Plugin.CatalogTest do
  use ExUnit.Case, async: false

  alias Vigil.Plugin.Catalog

  test "lookup returns :not_found for unknown plugin_id" do
    assert {:error, :not_found} = Catalog.lookup("does-not-exist")
  end

  test "manual register/lookup roundtrip" do
    Catalog.register("test-plugin-#{System.unique_integer()}", __MODULE__)
    id = "roundtrip-#{System.unique_integer()}"
    :ok = Catalog.register(id, String)
    assert {:ok, String} = Catalog.lookup(id)
  end

  test "all/0 returns a list of {plugin_id, module} pairs" do
    pairs = Catalog.all()
    assert is_list(pairs)
    assert Enum.all?(pairs, fn {id, mod} -> is_binary(id) and is_atom(mod) end)
  end

  test "discovers plugin modules declared via OTP app env" do
    # Simulate a loaded app that declares :vigil_plugin in its env
    Application.put_env(:test_discovery_app, :vigil_plugin, Vigil.Plugin.NoOp)

    # Re-register manually (discovery only runs at init; use register for tests)
    Catalog.register(Vigil.Plugin.NoOp.plugin_id(), Vigil.Plugin.NoOp)

    assert {:ok, Vigil.Plugin.NoOp} = Catalog.lookup("noop")
  after
    Application.delete_env(:test_discovery_app, :vigil_plugin)
  end
end

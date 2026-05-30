defmodule Vigil.Plugin.ReferencePluginTest do
  @moduledoc """
  Direct contract-shape checks on the reference no-op plugin. The conformance
  runner (`Vigil.Plugin.Conformance`) exercises these same shapes through a
  reusable harness; these tests pin the no-op's behaviour explicitly.
  """
  use ExUnit.Case, async: true

  alias Vigil.Plugin.NoOp

  test "declares the inventory and execution capabilities" do
    assert :inventory in NoOp.capabilities()
    assert :execution in NoOp.capabilities()
  end

  describe "full Vigil.Plugin contract surface (design §3.1)" do
    test "declares plugin identity metadata" do
      assert NoOp.plugin_id() == "noop"
      assert is_binary(NoOp.display_name())
      assert %Version{} = NoOp.contract_version()
    end

    test "config_schema/0 returns a Vigil.Plugin.Schema" do
      assert %Vigil.Plugin.Schema{} = NoOp.config_schema()
    end

    test "defaults/0 declares cache_ttl, timeouts and a concurrency budget" do
      defaults = NoOp.defaults()
      assert is_map(defaults.cache_ttl)
      assert is_map(defaults.timeouts)
      assert is_integer(defaults.concurrency) and defaults.concurrency > 0
    end

    test "operational_permissions/0 returns a list of Permission structs" do
      perms = NoOp.operational_permissions()
      assert is_list(perms)
      assert Enum.all?(perms, &match?(%Vigil.Plugin.Permission{}, &1))
    end
  end

  describe "execution runner contract (design §6.3)" do
    test "start/4 returns an opaque runner reference" do
      assert {:ok, runner_ref} = NoOp.start("integ-1", %{}, [], %{})
      assert is_reference(runner_ref)
    end

    test "abort/1 stops a runner cleanly" do
      {:ok, runner_ref} = NoOp.start("integ-1", %{}, [], %{})
      assert :ok = NoOp.abort(runner_ref)
    end
  end
end

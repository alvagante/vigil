defmodule Vigil.Plugin.ReloadTest do
  @moduledoc """
  Tests for hot-reload vs restart semantics (design §2.4, §3.6, issue #5).
  Exercises the no-op ConfigServer's classification of changed fields.
  """

  use ExUnit.Case, async: false

  alias Vigil.Plugin.NoOp.ConfigServer

  setup do
    integration_id = "reload-test-#{System.unique_integer([:positive])}"
    initial_config = %{"check_interval_ms" => 30_000}

    spec = Vigil.Plugin.NoOp.child_spec({integration_id, initial_config})
    {:ok, sup_pid} = DynamicSupervisor.start_child(Vigil.Integrations.Supervisor, spec)

    on_exit(fn ->
      if Process.alive?(sup_pid),
        do: DynamicSupervisor.terminate_child(Vigil.Integrations.Supervisor, sup_pid)
    end)

    %{integration_id: integration_id, sup_pid: sup_pid}
  end

  test "changing a :hot field does not stop the ConfigServer", %{integration_id: id} do
    new_config = %{"check_interval_ms" => 60_000}
    result = ConfigServer.reload(id, new_config)
    assert result == :hot

    # ConfigServer must still be alive
    [{pid, _}] = Registry.lookup(Vigil.Plugin.Registry, {:config_server, id})
    assert Process.alive?(pid)
    assert ConfigServer.get_config(id) == new_config
  end

  test "changing a :restart field causes the ConfigServer to stop", %{integration_id: id, sup_pid: sup} do
    [{config_pid_before, _}] = Registry.lookup(Vigil.Plugin.Registry, {:config_server, id})

    new_config = %{"endpoint_url" => "http://new-endpoint.local"}
    result = ConfigServer.reload(id, new_config)
    assert result == :restart

    # ConfigServer was stopped — supervisor will restart it with fresh config.
    # Wait briefly for the supervisor to restart the child.
    :timer.sleep(50)

    # The supervisor itself should still be alive
    assert Process.alive?(sup)

    # A new ConfigServer process should have been registered (different pid)
    case Registry.lookup(Vigil.Plugin.Registry, {:config_server, id}) do
      [{new_pid, _}] -> assert new_pid != config_pid_before
      # If supervisor restart is pending, the key may briefly be absent
      [] -> :ok
    end
  end

  test "Schema.validate/2 passes for valid no-op config" do
    schema = Vigil.Plugin.NoOp.config_schema()
    assert {:ok, _} = Vigil.Plugin.Schema.validate(schema, %{"check_interval_ms" => 5000})
  end

  test "Schema.validate/2 rejects wrong types" do
    schema = Vigil.Plugin.NoOp.config_schema()
    assert {:error, errors} = Vigil.Plugin.Schema.validate(schema, %{"check_interval_ms" => "not-an-int"})
    assert Enum.any?(errors, fn {field, _} -> field == "check_interval_ms" end)
  end
end

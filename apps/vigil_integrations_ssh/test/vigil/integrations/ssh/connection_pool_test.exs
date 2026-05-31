defmodule Vigil.Integrations.SSH.ConnectionPoolTest do
  use ExUnit.Case, async: true

  alias Vigil.Integrations.SSH.{ConnectionPool, FakeTransport}

  defp start_pool(agent) do
    start_supervised!(
      {ConnectionPool,
       integration_id: "test-#{System.unique_integer([:positive])}",
       transport: FakeTransport,
       transport_opts: [agent: agent]}
    )
  end

  test "reuses one connection across consecutive runs to the same host (SSH-302)" do
    agent = FakeTransport.new(%{responses: %{"echo hi" => {0, "hi\n", ""}}})
    pool = start_pool(agent)

    assert {:ok, %{stdout: "hi\n"}} = ConnectionPool.run(pool, "host-a", "echo hi")
    assert {:ok, %{stdout: "hi\n"}} = ConnectionPool.run(pool, "host-a", "echo hi")

    assert FakeTransport.connect_count(agent) == 1
  end

  test "opens a separate connection per host" do
    agent = FakeTransport.new()
    pool = start_pool(agent)

    ConnectionPool.run(pool, "host-a", "x")
    ConnectionPool.run(pool, "host-b", "x")

    assert FakeTransport.connect_count(agent) == 2
  end

  test "reconnects transparently when the cached connection is dead" do
    agent = FakeTransport.new(%{fail_exec_once: true, responses: %{"x" => {0, "ok", ""}}})
    pool = start_pool(agent)

    # First exec fails with :closed; the pool drops the connection, reconnects,
    # and retries — the caller sees a successful result, not the failure.
    assert {:ok, %{stdout: "ok"}} = ConnectionPool.run(pool, "host-a", "x")
    assert FakeTransport.connect_count(agent) == 2
  end

  test "surfaces connect failures as a structured Vigil.Plugin.Error" do
    agent = FakeTransport.new(%{connect_error: :econnrefused})
    pool = start_pool(agent)

    assert {:error, %Vigil.Plugin.Error{category: :transient_external, retriable?: true}} =
             ConnectionPool.run(pool, "unreachable", "x")
  end
end

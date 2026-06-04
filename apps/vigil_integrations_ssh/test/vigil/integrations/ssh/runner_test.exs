defmodule Vigil.Integrations.SSH.RunnerTest do
  use ExUnit.Case, async: true

  alias Vigil.Integrations.SSH.{ConnectionPool, FakeTransport, Runner}

  defp start_pool(agent) do
    start_supervised!(
      {ConnectionPool,
       integration_id: "test-#{System.unique_integer([:positive])}",
       transport: FakeTransport,
       transport_opts: [agent: agent]}
    )
  end

  defp run_start(artifact, targets, pool) do
    Runner.start("test-integration", artifact, targets, %{stream_pid: self(), pool: pool})
  end

  test "no targets: sends runner_done and returns ok" do
    agent = FakeTransport.new()
    pool = start_pool(agent)

    assert {:ok, pid} = run_start(%{text: "echo hi"}, [], pool)
    assert is_pid(pid)
    assert_receive {:runner_done, %{}}
  end

  test "one target: sends chunk, target_done, then runner_done in order" do
    agent = FakeTransport.new(%{responses: %{"echo hi" => {0, "hello\n", ""}}})
    pool = start_pool(agent)

    targets = [%{execution_id: "exec-1", node_id: "web-01"}]
    {:ok, _pid} = run_start(%{text: "echo hi"}, targets, pool)

    assert_receive {:runner_chunk, "exec-1", :text, "hello\n"}

    assert_receive {:runner_target_done, "exec-1", %{exit_status: 0, duration_ms: dur}}
                   when dur >= 0

    assert_receive {:runner_done, %{}}
  end

  test "non-zero exit status is forwarded in target_done" do
    agent = FakeTransport.new(%{responses: %{"bad_cmd" => {127, "", "not found\n"}}})
    pool = start_pool(agent)

    targets = [%{execution_id: "exec-2", node_id: "web-02"}]
    {:ok, _pid} = run_start(%{text: "bad_cmd"}, targets, pool)

    assert_receive {:runner_target_done, "exec-2", %{exit_status: 127}}
    assert_receive {:runner_done, %{}}
  end

  test "string-key artifact (DB round-trip form) works" do
    agent = FakeTransport.new(%{responses: %{"echo" => {0, "out\n", ""}}})
    pool = start_pool(agent)

    targets = [%{execution_id: "exec-3", node_id: "db-01"}]
    {:ok, _pid} = run_start(%{"text" => "echo"}, targets, pool)

    assert_receive {:runner_chunk, "exec-3", :text, "out\n"}
    assert_receive {:runner_done, %{}}
  end

  test "abort/1 kills the runner process" do
    agent = FakeTransport.new(%{responses: %{"sleep 60" => {0, "", ""}}})
    pool = start_pool(agent)

    {:ok, pid} =
      Runner.start(
        "test-integration",
        %{text: "sleep 60"},
        [%{execution_id: "exec-5", node_id: "host"}],
        %{stream_pid: self(), pool: pool}
      )

    assert Process.alive?(pid)
    assert :ok = Runner.abort(pid)

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
  end
end

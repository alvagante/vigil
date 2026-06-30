defmodule VigilWeb.ExecutionLiveTest do
  use VigilWeb.LiveCase, async: false

  alias Vigil.Core.{Execution.Group, Execution.Stream, IntegrationConfig}
  alias Vigil.Plugin.Catalog
  alias Vigil.Repo
  alias VigilWeb.ExecutionTestPlugin

  defmodule HangingRunner do
    def start(_integration_id, _artifact, _targets, _opts),
      do: {:ok, spawn(fn -> Process.sleep(:infinity) end)}

    def abort(pid), do: Process.exit(pid, :kill)
  end

  setup do
    Catalog.register("exec_test", ExecutionTestPlugin)
    :ok
  end

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user)}
  end

  defp start_exec_integration(name) do
    {:ok, integ} =
      IntegrationConfig.create(%{
        plugin_id: "exec_test",
        name: name,
        contract_version: "1.0.0",
        enabled: true
      })

    start_supervised!(ExecutionTestPlugin.child_spec({integ.id, %{}}))
    integ
  end

  defp insert_group(attrs \\ %{}) do
    Repo.insert!(
      %Group{
        integration_id: "test-int",
        artifact: %{kind: "command", text: "echo hello"},
        intended_targets: %{node_ids: ["web-01"]},
        dispatched_count: 1,
        submitted_by: "anon",
        submitted_at: DateTime.utc_now()
      }
      |> Map.merge(attrs)
    )
  end

  ## History page

  test "shows empty state when no executions", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/executions")
    assert html =~ "No executions yet"
  end

  test "lists execution groups ordered by most recent first", %{conn: conn} do
    insert_group()
    {:ok, _view, html} = live(conn, ~p"/executions")
    assert html =~ "echo hello"
  end

  test "outcome filter hides non-matching groups", %{conn: conn} do
    insert_group(%{artifact: %{kind: "command", text: "cmd-running"}})

    # Insert a completed group via a Record with outcome "ok"
    g2 = insert_group(%{artifact: %{kind: "command", text: "cmd-completed"}})

    Repo.insert!(%Vigil.Core.Execution.Record{
      execution_group_id: g2.id,
      integration_id: "test-int",
      node_id: "web-01",
      artifact: %{kind: "command", text: "cmd-completed"},
      outcome: "ok",
      streaming_state: "closed",
      started_at: DateTime.utc_now(),
      ended_at: DateTime.utc_now()
    })

    {:ok, _view, html} = live(conn, ~p"/executions?outcome=ok")

    assert html =~ "cmd-completed"
    refute html =~ "cmd-running"
  end

  ## Submit form

  test "renders command input form at /executions/new", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/executions/new")
    assert html =~ "Run Command"
    assert html =~ "command"
  end

  test "empty command shows validation error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/executions/new")

    html =
      view
      |> form("#execution-form", execution: %{command: "", integration_id: "", node_ids: ""})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
  end

  test "submitting valid command redirects to execution group page", %{conn: conn} do
    integ = start_exec_integration("exec-lab")

    {:ok, view, _html} = live(conn, ~p"/executions/new")

    assert {:error, {:live_redirect, %{to: path}}} =
             view
             |> form("#execution-form",
               execution: %{
                 command: "uptime",
                 integration_id: integ.id,
                 node_ids: "web-01"
               }
             )
             |> render_submit()

    assert path =~ "/executions/"
  end

  ## Submit form — task/plan dynamic forms (BOLT-203)

  test "form renders a kind selector with command, task, plan options", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/executions/new")
    assert html =~ ~r/value="command"/
    assert html =~ ~r/value="task"/
    assert html =~ ~r/value="plan"/
  end

  test "selecting kind=task shows a task name selector and hides command input",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/executions/new")

    html =
      view
      |> element("#execution-form")
      |> render_change(%{"execution" => %{"kind" => "task"}})

    assert html =~ "task_name"
    refute html =~ ~r/name="execution\[command\]"/
  end

  test "selecting kind=plan shows a plan name selector and hides command input",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/executions/new")

    html =
      view
      |> element("#execution-form")
      |> render_change(%{"execution" => %{"kind" => "plan"}})

    assert html =~ "plan_name"
    refute html =~ ~r/name="execution\[command\]"/
  end

  ## Execution group detail (streaming view)

  test "group detail shows execution artifact", %{conn: conn} do
    group = insert_group()
    {:ok, _view, html} = live(conn, ~p"/executions/#{group.id}")
    assert html =~ "echo hello"
  end

  test "re-run group button redirects to a new execution group", %{conn: conn} do
    integ = start_exec_integration("rerun-lab")

    # Insert a completed group
    group =
      Repo.insert!(%Vigil.Core.Execution.Group{
        integration_id: integ.id,
        artifact: %{kind: "command", text: "uptime"},
        intended_targets: %{node_ids: ["web-01"]},
        dispatched_count: 1,
        submitted_by: "anon",
        submitted_at: DateTime.utc_now()
      })

    Repo.insert!(%Vigil.Core.Execution.Record{
      execution_group_id: group.id,
      integration_id: integ.id,
      node_id: "web-01",
      artifact: %{kind: "command", text: "uptime"},
      outcome: "ok",
      streaming_state: "closed",
      started_at: DateTime.utc_now(),
      ended_at: DateTime.utc_now()
    })

    {:ok, view, _html} = live(conn, ~p"/executions/#{group.id}")

    assert {:error, {:live_redirect, %{to: path}}} =
             view |> element("#rerun-group-btn") |> render_click()

    assert path =~ "/executions/"
    refute path == "/executions/#{group.id}"
  end

  test "late-joining viewer sees already-buffered chunks without a new broadcast (STR-103)",
       %{conn: conn} do
    group = insert_group()

    record =
      Repo.insert!(%Vigil.Core.Execution.Record{
        execution_group_id: group.id,
        integration_id: "test-int",
        node_id: "web-01",
        artifact: %{kind: "command", text: "echo hello"},
        outcome: "running",
        streaming_state: "live",
        started_at: DateTime.utc_now()
      })

    {:ok, stream_pid} =
      Stream.start_link(%{
        runner_module: HangingRunner,
        integration_id: "test-int",
        artifact: %{kind: "command", text: "echo hello"},
        group_id: group.id,
        targets: [%{execution_id: record.id}]
      })

    on_exit(fn -> if Process.alive?(stream_pid), do: GenServer.stop(stream_pid) end)

    send(stream_pid, {:runner_chunk, record.id, :stdout, "already buffered\n"})
    # Sync: call through the same mailbox to ensure the send was processed
    Stream.get_buffer(group.id, record.id, 0)

    {:ok, _view, html} = live(conn, ~p"/executions/#{group.id}")

    assert html =~ "already buffered"
  end

  test "streaming chunk updates the view via PubSub", %{conn: conn} do
    group = insert_group()
    # Insert a bare Record so we can subscribe to its stream topic
    record =
      Repo.insert!(%Vigil.Core.Execution.Record{
        execution_group_id: group.id,
        integration_id: "test-int",
        node_id: "web-01",
        artifact: %{kind: "command", text: "echo hello"},
        outcome: "running",
        streaming_state: "live",
        started_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, ~p"/executions/#{group.id}")

    Phoenix.PubSub.broadcast(
      Vigil.PubSub,
      "execution_stream:#{record.id}",
      {:chunk, record.id, :stdout, 1, "live output line\n"}
    )

    assert render(view) =~ "live output line"
  end

  ## STR-201/202 — position-aware dedup and reconnect resume

  defp start_live_stream(group, attrs \\ []) do
    node_id = Keyword.get(attrs, :node_id, "web-01")

    record =
      Repo.insert!(%Vigil.Core.Execution.Record{
        execution_group_id: group.id,
        integration_id: "test-int",
        node_id: node_id,
        artifact: %{kind: "command", text: "echo hello"},
        outcome: "running",
        streaming_state: "live",
        started_at: DateTime.utc_now()
      })

    {:ok, stream_pid} =
      Stream.start_link(%{
        runner_module: HangingRunner,
        integration_id: "test-int",
        artifact: %{kind: "command", text: "echo hello"},
        group_id: group.id,
        targets: [%{execution_id: record.id}]
      })

    on_exit(fn -> if Process.alive?(stream_pid), do: GenServer.stop(stream_pid) end)
    {record, stream_pid}
  end

  test "duplicate PubSub chunk at already-seen position is not rendered (STR-201)",
       %{conn: conn} do
    group = insert_group()
    {record, stream_pid} = start_live_stream(group)

    send(stream_pid, {:runner_chunk, record.id, :stdout, "original-content\n"})
    Stream.get_buffer(group.id, record.id, 0)

    {:ok, view, html} = live(conn, ~p"/executions/#{group.id}")
    assert html =~ "original-content"

    # Re-broadcast position 1 — already seen from spool
    Phoenix.PubSub.broadcast(
      Vigil.PubSub,
      "execution_stream:#{record.id}",
      {:chunk, record.id, :stdout, 1, "stale-duplicate\n"}
    )

    refute render(view) =~ "stale-duplicate"
  end

  test "connecting with position URL param starts spool replay after that position (STR-201)",
       %{conn: conn} do
    group = insert_group()
    {record, stream_pid} = start_live_stream(group)

    send(stream_pid, {:runner_chunk, record.id, :stdout, "before-resume\n"})
    send(stream_pid, {:runner_chunk, record.id, :stdout, "after-resume\n"})
    Stream.get_buffer(group.id, record.id, 0)

    # pos[record.id]=1 means "I've seen up to position 1" — should replay from pos 2 only
    {:ok, _view, html} = live(conn, "/executions/#{group.id}?pos[#{record.id}]=1")

    refute html =~ "before-resume"
    assert html =~ "after-resume"
  end

  ## STR-204 — long-absent user sees completed transcript

  test "STR-204: closed execution with plain transcript is rendered (normal completion)",
       %{conn: conn} do
    group = insert_group()

    Repo.insert!(%Vigil.Core.Execution.Record{
      execution_group_id: group.id,
      integration_id: "test-int",
      node_id: "web-01",
      artifact: %{kind: "command", text: "echo hello"},
      outcome: "ok",
      streaming_state: "closed",
      transcript: "hello from history\n",
      started_at: DateTime.utc_now(),
      ended_at: DateTime.utc_now()
    })

    {:ok, _view, html} = live(conn, ~p"/executions/#{group.id}")

    assert html =~ "hello from history"
  end

  test "STR-204: aborted-by-restart execution shows readable transcript",
       %{conn: conn} do
    group = insert_group()

    # transcript is plain text — the invariant enforced by Recovery.recover_record/1
    Repo.insert!(%Vigil.Core.Execution.Record{
      execution_group_id: group.id,
      integration_id: "test-int",
      node_id: "web-01",
      artifact: %{kind: "command", text: "echo hello"},
      outcome: "aborted_by_restart",
      streaming_state: "closed",
      transcript: "partial output\n[EXECUTION ABORTED]\n",
      started_at: DateTime.utc_now(),
      ended_at: DateTime.utc_now()
    })

    {:ok, _view, html} = live(conn, ~p"/executions/#{group.id}")

    assert html =~ "partial output"
    assert html =~ "ABORTED"
  end

  test "ack event pushes updated position into the URL (STR-202)", %{conn: conn} do
    group = insert_group()
    {record, _stream_pid} = start_live_stream(group)

    {:ok, view, _html} = live(conn, ~p"/executions/#{group.id}")

    render_hook(view, "ack_execution_output", %{
      "execution_id" => record.id,
      "position" => "7"
    })

    assert_patch(view, "/executions/#{group.id}?pos%5B#{record.id}%5D=7")
  end
end

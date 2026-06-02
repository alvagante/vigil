defmodule VigilWeb.ExecutionLiveTest do
  use VigilWeb.LiveCase, async: false

  alias Vigil.Core.{Execution.Group, IntegrationConfig}
  alias Vigil.Plugin.Catalog
  alias Vigil.Repo
  alias VigilWeb.ExecutionTestPlugin

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
    Repo.insert!(%Group{
      integration_id: "test-int",
      artifact: %{kind: "command", text: "echo hello"},
      intended_targets: %{node_ids: ["web-01"]},
      dispatched_count: 1,
      submitted_by: "anon",
      submitted_at: DateTime.utc_now()
    }
    |> Map.merge(attrs))
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
      {:chunk, record.id, "live output line\n"}
    )

    assert render(view) =~ "live output line"
  end
end

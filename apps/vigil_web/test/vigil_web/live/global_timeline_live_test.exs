defmodule VigilWeb.GlobalTimelineLiveTest do
  use VigilWeb.LiveCase, async: false

  alias Vigil.Core.Journal

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "renders the global journal page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/journal")
    assert html =~ "Journal"
  end

  test "displays execution entries from all nodes", %{conn: conn} do
    Journal.create_execution_entry(%{node_id: "alpha", summary: "ran uptime", occurred_at: DateTime.utc_now()})
    Journal.create_execution_entry(%{node_id: "beta", summary: "ran hostname", occurred_at: DateTime.utc_now()})

    {:ok, view, _html} = live(conn, ~p"/journal")
    html = render(view)

    assert html =~ "ran uptime"
    assert html =~ "ran hostname"
    assert html =~ "alpha"
    assert html =~ "beta"
  end

  test "server-side node filter returns only that node's entries", %{conn: conn} do
    Journal.create_execution_entry(%{node_id: "node-filter-a", summary: "entry-a", occurred_at: DateTime.utc_now()})
    Journal.create_execution_entry(%{node_id: "node-filter-b", summary: "entry-b", occurred_at: DateTime.utc_now()})

    {:ok, view, _html} = live(conn, ~p"/journal")

    html =
      view
      |> element("form")
      |> render_change(%{"node_id" => "node-filter-a", "entry_type" => "", "severity" => ""})

    assert html =~ "entry-a"
    refute html =~ "entry-b"
  end

  test "live update: new execution entry appears without refresh", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/journal")

    Journal.create_execution_entry(%{
      node_id: "live-node",
      summary: "live-pushed-entry",
      occurred_at: DateTime.utc_now()
    })

    # Give PubSub time to deliver
    :timer.sleep(100)
    assert render(view) =~ "live-pushed-entry"
  end

  test "soft-deleted note does not appear on global timeline", %{conn: conn, user: user} do
    {:ok, entry} = Journal.Notes.create(user, %{node_id: "del-node", summary: "will-be-deleted"})

    {:ok, view, _html} = live(conn, ~p"/journal")
    assert render(view) =~ "will-be-deleted"

    Journal.Notes.delete(user, entry.id)
    :timer.sleep(100)

    refute render(view) =~ "will-be-deleted"
  end
end

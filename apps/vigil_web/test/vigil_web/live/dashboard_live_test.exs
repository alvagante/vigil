defmodule VigilWeb.DashboardLiveTest do
  use VigilWeb.LiveCase, async: true

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user)}
  end

  test "GET / renders the ERR-801/802 empty state when no integrations are configured",
       %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)

    assert body =~ "no integrations configured"
    assert body =~ "Puppet"
    assert body =~ "Ansible"
    assert body =~ "SSH"
    assert body =~ "Bolt"
  end
end

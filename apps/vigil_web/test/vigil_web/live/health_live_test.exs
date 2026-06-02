defmodule VigilWeb.Live.HealthLiveTest do
  use VigilWeb.LiveCase, async: false

  alias Vigil.Core.IntegrationConfig

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user)}
  end

  test "renders the integration health header", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/health")
    assert html =~ "Integration Health"
  end

  test "shows the empty state when no integrations are configured", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/health")
    assert html =~ "No integrations configured"
  end

  test "shows each configured integration with starting status", %{conn: conn} do
    {:ok, _} = IntegrationConfig.create(%{plugin_id: "noop", name: "health-noop", contract_version: "1.0.0"})
    {:ok, _view, html} = live(conn, ~p"/health")
    assert html =~ "health-noop"
    assert html =~ "starting"
  end

  test "updates status when health PubSub message arrives", %{conn: conn} do
    {:ok, integration} =
      IntegrationConfig.create(%{plugin_id: "noop", name: "live-health-noop", contract_version: "1.0.0"})

    {:ok, view, _html} = live(conn, ~p"/health")

    id = integration.id

    Phoenix.PubSub.broadcast(
      Vigil.PubSub,
      "integration_health:#{id}",
      {:health, id, :healthy, [:inventory], %{}}
    )

    assert render(view) =~ "healthy"
  end
end

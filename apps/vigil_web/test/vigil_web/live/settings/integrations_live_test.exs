defmodule VigilWeb.Live.Settings.IntegrationsLiveTest do
  use VigilWeb.LiveCase, async: false

  alias Vigil.Core.IntegrationConfig

  setup do
    Vigil.Plugin.Catalog.register("noop", Vigil.Plugin.NoOp)
    :ok
  end

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user)}
  end

  test "renders the empty state when no integrations are configured", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/integrations")
    assert render(view) =~ "No integrations configured"
  end

  test "lists existing integrations", %{conn: conn} do
    {:ok, _} = IntegrationConfig.create(%{plugin_id: "noop", name: "my-noop", contract_version: "1.0.0"})
    {:ok, view, _html} = live(conn, ~p"/settings/integrations")
    assert render(view) =~ "my-noop"
    assert render(view) =~ "noop"
  end

  test "admin can open the new integration form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/integrations")
    view |> element("button", "New Integration") |> render_click()
    assert render(view) =~ "New Integration"
    assert render(view) =~ "Plugin"
  end

  test "admin can cancel the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/integrations")
    view |> element("button", "New Integration") |> render_click()
    view |> element("button", "Cancel") |> render_click()
    refute render(view) =~ "select plugin"
  end

  test "admin can create a no-op integration", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/integrations")
    view |> element("button", "New Integration") |> render_click()

    view
    |> form("form", integration: %{plugin_id: "noop", name: "test-noop", contract_version: "1.0.0"})
    |> render_submit()

    assert render(view) =~ "test-noop"
    assert render(view) =~ "Integration saved"
    assert IntegrationConfig.list_all() |> Enum.any?(&(&1.name == "test-noop"))
  end

  test "user without platform:admin permission is redirected away" do
    unprivileged_conn = log_in_user(Phoenix.ConnTest.build_conn(), user_fixture(%{role: :none}))
    assert {:error, {:redirect, %{to: "/"}}} = live(unprivileged_conn, ~p"/settings/integrations")
  end

  test "enable and disable buttons toggle the enabled state", %{conn: conn} do
    {:ok, integration} =
      IntegrationConfig.create(%{
        plugin_id: "noop",
        name: "toggle-test",
        contract_version: "1.0.0",
        enabled: false
      })

    {:ok, view, _html} = live(conn, ~p"/settings/integrations")
    assert render(view) =~ "toggle-test"

    view |> element("button", "Enable") |> render_click()
    assert render(view) =~ "Integration enabled"

    updated = IntegrationConfig.get!(integration.id)
    assert updated.enabled == true
  end
end

defmodule VigilWeb.InventoryLiveTest do
  use VigilWeb.LiveCase, async: false

  alias Vigil.Core.IntegrationConfig
  alias Vigil.Plugin.Catalog
  alias VigilWeb.{Inventory, InventoryTestPlugin}

  setup do
    Catalog.register("web_test", InventoryTestPlugin)
    :ok
  end

  defp start_source(name) do
    {:ok, integ} =
      IntegrationConfig.create(%{
        plugin_id: "web_test",
        name: name,
        contract_version: "1.0.0",
        enabled: true
      })

    start_supervised!(InventoryTestPlugin.child_spec({integ.id, %{}}))
    integ
  end

  test "shows the first-run empty state when no inventory sources are enabled", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/inventory")
    assert html =~ "No inventory sources are enabled"
  end

  test "renders nodes with source attribution (INV-201)", %{conn: conn} do
    start_source("lab-inventory")

    {:ok, _view, html} = live(conn, ~p"/inventory")

    assert html =~ "alpha"
    # Source attribution: the integration name is shown on the row.
    assert html =~ "lab-inventory"
  end

  test "flags wildcard nodes as non-targetable (SSH-103 surfaced generically)", %{conn: conn} do
    start_source("lab-inventory")

    {:ok, _view, html} = live(conn, ~p"/inventory")

    assert html =~ "*.wild"
    # The wildcard row carries the SSH-103 tooltip rationale.
    assert html =~ "Wildcard pattern"
  end

  test "node rows link to the node detail page", %{conn: conn} do
    integ = start_source("lab-inventory")
    node_id = Inventory.encode_id(integ.id, "alpha")

    {:ok, view, _html} = live(conn, ~p"/inventory")

    assert has_element?(view, ~s{a[href="/inventory/node/#{node_id}"]}, "alpha")
  end
end

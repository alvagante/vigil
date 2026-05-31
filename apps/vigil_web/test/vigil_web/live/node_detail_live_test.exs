defmodule VigilWeb.NodeDetailLiveTest do
  use VigilWeb.LiveCase, async: false

  alias Vigil.Core.IntegrationConfig
  alias Vigil.Plugin.Catalog
  alias VigilWeb.{Inventory, InventoryTestPlugin}

  setup do
    Catalog.register("web_test", InventoryTestPlugin)

    {:ok, integ} =
      IntegrationConfig.create(%{
        plugin_id: "web_test",
        name: "lab-detail",
        contract_version: "1.0.0",
        enabled: true
      })

    start_supervised!(InventoryTestPlugin.child_spec({integ.id, %{}}))
    {:ok, integ: integ}
  end

  test "renders the node header with source attribution", %{conn: conn, integ: integ} do
    node_id = Inventory.encode_id(integ.id, "alpha")
    {:ok, _view, html} = live(conn, ~p"/inventory/node/#{node_id}")

    assert html =~ "alpha"
    assert html =~ "lab-detail"
  end

  test "loads the Facts tab asynchronously and renders the facts table", %{
    conn: conn,
    integ: integ
  } do
    node_id = Inventory.encode_id(integ.id, "alpha")
    {:ok, view, _html} = live(conn, ~p"/inventory/node/#{node_id}")

    html = render_async(view)
    assert html =~ "os.distro"
    assert html =~ "ubuntu"
    assert html =~ "cpu.count"
  end

  test "contains the facts failure to the tab when the source errors", %{conn: conn, integ: integ} do
    # "*.wild" is returned by the test plugin's get_facts as an error.
    node_id = Inventory.encode_id(integ.id, "*.wild")
    {:ok, view, _html} = live(conn, ~p"/inventory/node/#{node_id}")

    html = render_async(view)
    assert html =~ "Facts unavailable"
  end

  test "redirects to the inventory list for an unknown node", %{conn: conn} do
    bogus = Inventory.encode_id("00000000-0000-0000-0000-000000000000", "nope")

    assert {:error, {:live_redirect, %{to: "/inventory"}}} =
             live(conn, ~p"/inventory/node/#{bogus}")
  end
end

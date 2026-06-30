defmodule VigilWeb.InventoryLiveTest do
  use VigilWeb.LiveCase, async: false

  alias Vigil.Core.IntegrationConfig
  alias Vigil.Plugin.Catalog
  alias VigilWeb.{Inventory, InventoryTestPlugin}

  setup do
    Catalog.register("web_test", InventoryTestPlugin)
    :ok
  end

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user)}
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

  describe "ADR-0006 invariant — cache is unfiltered; RBAC applied at boundary" do
    # This test verifies the structural property from ADR-0006: the shared ETS
    # cache stores the full unfiltered integration result. RBAC scope reduction
    # is applied by list_inventory/2 before any data leaves the module — never
    # by the Dispatcher or the cache layer itself.
    test "zero-permission user sees no nodes even when cache is already populated" do
      integ = start_source("invariant-test")
      admin = user_fixture()

      # Admin populates the cache (cache now holds all nodes for this integration).
      %{total_filtered: admin_total} = Inventory.list_inventory(admin, [])
      assert admin_total > 0

      # Restricted user reads from the same integration — same ETS entry, but
      # list_inventory/2 must apply filter_targets/3 before returning.
      restricted = user_fixture(%{role: :none})
      %{nodes: nodes, total_filtered: total} = Inventory.list_inventory(restricted, [])

      assert nodes == []
      assert total == 0,
             "Cache for #{integ.id} was populated with #{admin_total} nodes; " <>
               "restricted reader must see 0, not #{total}"
    end
  end

  describe "list_inventory/2 — RBAC filtering and cursor pagination (EXS-008, ADR-0006)" do
    test "admin principal sees all nodes from an enabled integration" do
      integ = start_source("filter-test")
      admin = user_fixture()

      %{nodes: nodes, total_filtered: total} = Inventory.list_inventory(admin, [])

      assert total == 2
      assert length(nodes) == 2
      source_ids = Enum.map(nodes, fn n -> n.source.integration_id end)
      assert integ.id in source_ids
    end

    test "principal with no inventory:node:read sees zero nodes" do
      start_source("perm-test")
      user = user_fixture(%{role: :none})

      %{nodes: nodes, total_filtered: total} = Inventory.list_inventory(user, [])

      assert nodes == []
      assert total == 0
    end

    test "page_size limits returned nodes; next_cursor is set when more remain" do
      start_source("page-test")
      admin = user_fixture()

      %{nodes: page, next_cursor: cursor, total_filtered: total} =
        Inventory.list_inventory(admin, page_size: 1)

      assert total == 2
      assert length(page) == 1
      assert cursor != nil
    end

    test "next_cursor is nil when all filtered nodes fit in one page" do
      start_source("no-cursor-test")
      admin = user_fixture()

      %{nodes: page, next_cursor: cursor} = Inventory.list_inventory(admin, page_size: 10)

      assert length(page) == 2
      assert cursor == nil
    end

    test "cursor advances the page — second page returns remaining nodes" do
      start_source("cursor-advance-test")
      admin = user_fixture()

      %{nodes: page1, next_cursor: cursor} = Inventory.list_inventory(admin, page_size: 1)
      assert length(page1) == 1
      assert cursor != nil

      %{nodes: page2, next_cursor: nil} =
        Inventory.list_inventory(admin, cursor: cursor, page_size: 1)

      assert length(page2) == 1
      # No overlap between pages.
      assert MapSet.disjoint?(
               MapSet.new(page1, & &1.id),
               MapSet.new(page2, & &1.id)
             )
    end
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

defmodule Vigil.Core.IntegrationConfigTest do
  use Vigil.DataCase, async: true

  alias Vigil.Core.IntegrationConfig
  alias Vigil.Core.Integration

  @valid_attrs %{
    plugin_id: "noop",
    name: "noop-test",
    contract_version: "1.0.0",
    config: %{}
  }

  describe "create/1" do
    test "creates an integration with valid attrs" do
      assert {:ok, %Integration{} = integration} = IntegrationConfig.create(@valid_attrs)
      assert integration.plugin_id == "noop"
      assert integration.name == "noop-test"
      assert integration.enabled == true
    end

    test "returns error changeset when name is missing" do
      assert {:error, changeset} =
               IntegrationConfig.create(%{plugin_id: "noop", contract_version: "1.0.0"})

      assert %{name: [_ | _]} = errors_on(changeset)
    end

    test "returns error changeset when name contains invalid chars" do
      attrs = Map.put(@valid_attrs, :name, "My Integration")
      assert {:error, changeset} = IntegrationConfig.create(attrs)
      assert %{name: [_ | _]} = errors_on(changeset)
    end

    test "returns error on duplicate name within same tenant" do
      {:ok, _} = IntegrationConfig.create(@valid_attrs)
      assert {:error, changeset} = IntegrationConfig.create(@valid_attrs)
      assert %{name: [_ | _]} = errors_on(changeset)
    end
  end

  describe "list_all/0 and list_enabled/0" do
    setup do
      {:ok, enabled} = IntegrationConfig.create(@valid_attrs)

      {:ok, disabled} =
        IntegrationConfig.create(
          Map.merge(@valid_attrs, %{name: "noop-disabled", enabled: false})
        )

      %{enabled: enabled, disabled: disabled}
    end

    test "list_all returns both enabled and disabled" do
      all = IntegrationConfig.list_all()
      assert length(all) >= 2
    end

    test "list_enabled returns only enabled integrations", %{enabled: e} do
      enabled = IntegrationConfig.list_enabled()
      ids = Enum.map(enabled, & &1.id)
      assert e.id in ids
    end
  end

  describe "enable/1 and disable/1" do
    setup do
      {:ok, integration} =
        IntegrationConfig.create(
          Map.merge(@valid_attrs, %{name: "noop-lifecycle", enabled: false})
        )

      %{integration: integration}
    end

    test "enable/1 sets enabled=true and broadcasts PubSub event", %{integration: integration} do
      id = integration.id
      Phoenix.PubSub.subscribe(Vigil.PubSub, "integration_lifecycle")

      {:ok, updated} = IntegrationConfig.enable(id)
      assert updated.enabled == true

      assert_receive {:integration_enabled, ^id}
    end

    test "disable/1 sets enabled=false and broadcasts PubSub event", %{integration: integration} do
      id = integration.id
      {:ok, _} = IntegrationConfig.enable(id)
      Phoenix.PubSub.subscribe(Vigil.PubSub, "integration_lifecycle")

      {:ok, updated} = IntegrationConfig.disable(id)
      assert updated.enabled == false

      assert_receive {:integration_disabled, ^id}
    end
  end

  describe "update/2" do
    setup do
      {:ok, integration} = IntegrationConfig.create(%{@valid_attrs | name: "noop-update"})
      %{integration: integration}
    end

    test "updates config and broadcasts config_updated event", %{integration: integration} do
      id = integration.id
      Phoenix.PubSub.subscribe(Vigil.PubSub, "integration_lifecycle")

      new_config = %{"check_interval_ms" => 60_000}
      {:ok, updated} = IntegrationConfig.update(integration, %{config: new_config})
      assert updated.config == new_config

      assert_receive {:integration_config_updated, ^id, ^new_config}
    end
  end
end

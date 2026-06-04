defmodule Vigil.Core.Integration do
  @moduledoc """
  Ecto schema for a configured integration instance (design §4.3.5).

  One row per configured integration instance. `plugin_id` references a plugin
  type (e.g., `"noop"`, `"puppet"`); multiple rows with the same `plugin_id` are
  allowed, giving each instance its own supervision subtree and health tracking.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @default_tenant "00000000-0000-0000-0000-000000000000"

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "integrations" do
    field(:tenant_id, :binary_id, default: @default_tenant)
    field(:plugin_id, :string)
    field(:name, :string)
    field(:config, :map, default: %{})
    field(:enabled, :boolean, default: true)
    field(:contract_version, :string)
    field(:health, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @required [:plugin_id, :name, :contract_version]
  @optional [:tenant_id, :config, :enabled, :health]

  def changeset(integration, attrs) do
    integration
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_format(:name, ~r/\A[a-z0-9_-]+\z/,
      message: "must be lowercase letters, digits, hyphens, or underscores"
    )
    |> unique_constraint(:name, name: :integrations_tenant_id_name_index)
  end

  def enable_changeset(integration) do
    change(integration, enabled: true)
  end

  def disable_changeset(integration) do
    change(integration, enabled: false)
  end

  def health_changeset(integration, health_attrs) do
    change(integration, health: health_attrs)
  end
end

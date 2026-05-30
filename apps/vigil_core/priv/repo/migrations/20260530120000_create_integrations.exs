defmodule Vigil.Repo.Migrations.CreateIntegrations do
  use Ecto.Migration

  @default_tenant "00000000-0000-0000-0000-000000000000"

  def change do
    create table(:integrations, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, :uuid, null: false, default: @default_tenant
      add :plugin_id, :string, null: false
      add :name, :string, null: false
      add :config, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true
      add :contract_version, :string, null: false
      add :health, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:integrations, [:tenant_id, :name])
    create index(:integrations, [:plugin_id])
    create index(:integrations, [:enabled])
  end
end

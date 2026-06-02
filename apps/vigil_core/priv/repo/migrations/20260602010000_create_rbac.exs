defmodule Vigil.Repo.Migrations.CreateRbac do
  use Ecto.Migration

  def change do
    create table(:roles, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, :uuid, null: false, default: fragment("'00000000-0000-0000-0000-000000000000'::uuid")
      add :name, :text, null: false
      add :description, :text
      add :built_in, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:roles, [:tenant_id, :name])

    create table(:role_permissions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :role_id, references(:roles, type: :uuid, on_delete: :delete_all), null: false
      add :action, :text, null: false
      add :integration_id, :uuid
      add :target_selector, :map
      add :command_policy, :map

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:role_permissions, [:role_id])
    create index(:role_permissions, [:action])

    create table(:user_roles, primary_key: false) do
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :role_id, references(:roles, type: :uuid, on_delete: :delete_all), null: false
      add :source, :text, null: false
      add :assigned_at, :utc_datetime_usec, null: false
      add :assigned_by, references(:users, type: :uuid, on_delete: :nilify_all)
    end

    create index(:user_roles, [:user_id])
    create index(:user_roles, [:role_id])
    execute(
      "ALTER TABLE user_roles ADD PRIMARY KEY (user_id, role_id, source)",
      "ALTER TABLE user_roles DROP CONSTRAINT user_roles_pkey"
    )
  end
end

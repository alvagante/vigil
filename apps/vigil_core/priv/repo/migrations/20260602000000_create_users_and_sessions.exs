defmodule Vigil.Repo.Migrations.CreateUsersAndSessions do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, :uuid, null: false, default: fragment("'00000000-0000-0000-0000-000000000000'::uuid")
      add :username, :text, null: false
      add :email, :text
      add :display_name, :text
      add :password_hash, :text
      add :auth_source, :text, null: false, default: "local"
      add :external_subject, :text
      add :status, :text, null: false, default: "active"
      add :is_break_glass, :boolean
      add :last_login_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:tenant_id, :username])
    create unique_index(:users, [:tenant_id, :auth_source, :external_subject],
      where: "external_subject IS NOT NULL",
      name: :users_external_unique_idx
    )
    create unique_index(:users, [:tenant_id],
      where: "is_break_glass IS TRUE",
      name: :users_break_glass_uniq
    )

    create constraint(:users, :valid_status, check: "status IN ('active', 'disabled', 'locked')")
    create constraint(:users, :valid_auth_source,
      check: "auth_source IN ('local') OR auth_source LIKE 'oidc:%' OR auth_source LIKE 'saml:%' OR auth_source LIKE 'ldap:%'"
    )

    create table(:sessions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :last_active_at, :utc_datetime_usec, null: false
      add :absolute_expires_at, :utc_datetime_usec, null: false
      add :idle_expires_at, :utc_datetime_usec, null: false
      add :client_meta, :map, null: false, default: %{}
    end

    create unique_index(:sessions, [:token_hash])
    create index(:sessions, [:user_id])
  end
end

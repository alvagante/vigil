defmodule Vigil.Repo.Migrations.AddJournalSoftDelete do
  use Ecto.Migration

  def change do
    alter table(:journal_entries) do
      add :deleted_at, :utc_datetime_usec, null: true
    end

    # Global timeline queries order by occurred_at across all tenants
    create index(:journal_entries, [:tenant_id, :occurred_at])
  end
end

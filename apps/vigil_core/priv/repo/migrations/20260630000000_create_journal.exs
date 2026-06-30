defmodule Vigil.Repo.Migrations.CreateJournal do
  use Ecto.Migration

  def change do
    create table(:journal_entries, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, :uuid, null: false, default: fragment("'00000000-0000-0000-0000-000000000000'::uuid")
      # Plain string, consistent with executions.node_id; FK to nodes table deferred until #22.
      add :node_id, :string, null: false
      add :entry_type, :text, null: false
      add :summary, :text, null: false
      add :detail, :map
      add :severity, :text, null: false, default: "informational"
      add :occurred_at, :utc_datetime_usec, null: false

      add :execution_id,
          references(:executions, type: :uuid, on_delete: :nilify_all)

      add :author_user_id,
          references(:users, type: :uuid, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:journal_entries, [:node_id, :occurred_at])
    create index(:journal_entries, [:entry_type])
    create index(:journal_entries, [:tenant_id])

    create constraint(:journal_entries, :valid_entry_type,
             check: "entry_type IN ('execution', 'manual_note')"
           )

    create constraint(:journal_entries, :valid_severity,
             check: "severity IN ('informational', 'notice', 'warning', 'error')"
           )

    create table(:journal_note_revisions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :journal_entry_id,
          references(:journal_entries, type: :uuid, on_delete: :delete_all),
          null: false

      add :editor_user_id,
          references(:users, type: :uuid, on_delete: :nilify_all)

      add :previous_summary, :text, null: false
      add :previous_detail, :map

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:journal_note_revisions, [:journal_entry_id])
  end
end

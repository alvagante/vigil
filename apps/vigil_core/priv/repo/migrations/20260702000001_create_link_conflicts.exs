defmodule Vigil.Repo.Migrations.CreateLinkConflicts do
  use Ecto.Migration

  def change do
    create table(:link_conflicts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, :binary_id, null: false

      # Full observation snapshot that triggered the conflict
      add :observation, :map, null: false

      # List of candidate node_ids with reasons: [%{node_id: ..., attrs_matched: [...]}]
      add :candidates, :map, null: false

      add :detected_at, :utc_datetime_usec, null: false
      add :resolved_at, :utc_datetime_usec

      # %{manual_link: node_id} | %{manual_unlink: "all"}
      add :resolution, :map
    end

    create index(:link_conflicts, [:tenant_id, :detected_at])
    create index(:link_conflicts, [:tenant_id, :resolved_at],
             where: "resolved_at IS NULL",
             name: "link_conflicts_unresolved_idx"
           )
  end
end

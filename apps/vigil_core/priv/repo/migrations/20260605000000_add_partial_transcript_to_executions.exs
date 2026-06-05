defmodule Vigil.Repo.Migrations.AddPartialTranscriptToExecutions do
  use Ecto.Migration

  def change do
    alter table(:executions) do
      add :partial_transcript, :binary
    end
  end
end

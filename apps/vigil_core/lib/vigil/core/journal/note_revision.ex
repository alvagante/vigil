defmodule Vigil.Core.Journal.NoteRevision do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "journal_note_revisions" do
    field(:previous_summary, :string)
    field(:previous_detail, :map)

    belongs_to(:journal_entry, Vigil.Core.Journal.Entry,
      foreign_key: :journal_entry_id,
      type: :binary_id
    )

    belongs_to(:editor, Vigil.Core.Accounts.User,
      foreign_key: :editor_user_id,
      type: :binary_id
    )

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

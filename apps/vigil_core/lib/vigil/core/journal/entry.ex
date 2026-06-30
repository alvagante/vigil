defmodule Vigil.Core.Journal.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "journal_entries" do
    field(:tenant_id, Ecto.UUID)
    field(:node_id, :string)
    field(:entry_type, :string)
    field(:summary, :string)
    field(:detail, :map)
    field(:severity, :string, default: "informational")
    field(:occurred_at, :utc_datetime_usec)

    belongs_to(:execution, Vigil.Core.Execution.Record,
      foreign_key: :execution_id,
      type: :binary_id
    )

    belongs_to(:author, Vigil.Core.Accounts.User,
      foreign_key: :author_user_id,
      type: :binary_id
    )

    timestamps(type: :utc_datetime_usec)
  end

  @required [:node_id, :entry_type, :summary]
  @optional [:detail, :severity, :occurred_at, :execution_id, :author_user_id, :tenant_id]

  def execution_changeset(entry, attrs) do
    entry
    |> cast(attrs, @required ++ @optional)
    |> put_change(:entry_type, "execution")
    |> put_default_occurred_at()
    |> validate_required(@required)
    |> validate_inclusion(:severity, ~w(informational notice warning error))
  end

  def note_changeset(entry, attrs) do
    entry
    |> cast(attrs, @required ++ @optional)
    |> put_change(:entry_type, "manual_note")
    |> put_default_occurred_at()
    |> validate_required(@required)
    |> validate_inclusion(:severity, ~w(informational notice warning error))
  end

  defp put_default_occurred_at(changeset) do
    if get_field(changeset, :occurred_at) do
      changeset
    else
      put_change(changeset, :occurred_at, DateTime.utc_now())
    end
  end
end

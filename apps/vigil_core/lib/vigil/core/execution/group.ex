defmodule Vigil.Core.Execution.Group do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "execution_groups" do
    field(:integration_id, :string)
    field(:artifact, :map)
    field(:intended_targets, :map, default: %{})
    field(:dispatched_count, :integer, default: 0)
    field(:denied_count, :integer, default: 0)
    field(:submitted_by, :string)
    field(:submitted_at, :utc_datetime_usec)

    has_many(:executions, Vigil.Core.Execution.Record, foreign_key: :execution_group_id)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [
      :integration_id,
      :artifact,
      :intended_targets,
      :dispatched_count,
      :denied_count,
      :submitted_by,
      :submitted_at
    ])
    |> validate_required([:integration_id, :artifact, :dispatched_count, :submitted_at])
  end
end

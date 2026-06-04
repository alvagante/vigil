defmodule Vigil.Core.Audit.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @valid_results ~w(pending success denied failure error)

  schema "audit_entries" do
    field(:tenant_id, :binary_id, default: "00000000-0000-0000-0000-000000000000")

    field(:occurred_at, :utc_datetime_usec)
    field(:actor_user_id, :binary_id)
    field(:actor_label, :string)
    field(:action, :string)
    field(:target_kind, :string)
    field(:target_id, :string)
    field(:params, :map, default: %{})
    field(:result, :string)
    field(:correlation_id, :string)
    field(:request_meta, :map, default: %{})
    field(:finalized_at, :utc_datetime_usec)
  end

  def create_changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :tenant_id,
      :occurred_at,
      :actor_user_id,
      :actor_label,
      :action,
      :target_kind,
      :target_id,
      :params,
      :result,
      :correlation_id,
      :request_meta,
      :finalized_at
    ])
    |> validate_required([:occurred_at, :action, :result])
    |> validate_inclusion(:result, @valid_results)
    |> validate_finalized_at_set_when_not_pending()
  end

  # Used only by Audit.finalize/2 — transitions a pending entry to a terminal state.
  def finalize_changeset(%__MODULE__{result: "pending"} = entry, result, finalized_at)
      when result in ~w(success denied failure error) do
    change(entry, result: result, finalized_at: finalized_at)
  end

  # Rejects any structural field update on a finalized entry at the changeset level.
  def update_changeset(%__MODULE__{result: result} = entry, attrs)
      when result != "pending" do
    entry
    |> cast(attrs, [:action, :target_kind, :target_id, :params])
    |> add_error(:result, "finalized entries are immutable")
  end

  defp validate_finalized_at_set_when_not_pending(changeset) do
    case get_field(changeset, :result) do
      "pending" ->
        changeset

      nil ->
        changeset

      _ ->
        validate_required(changeset, [:finalized_at])
    end
  end
end

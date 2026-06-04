defmodule Vigil.Core.Accounts.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sessions" do
    belongs_to(:user, Vigil.Core.Accounts.User)

    field(:token_hash, :binary)
    field(:created_at, :utc_datetime_usec)
    field(:last_active_at, :utc_datetime_usec)
    field(:absolute_expires_at, :utc_datetime_usec)
    field(:idle_expires_at, :utc_datetime_usec)
    field(:client_meta, :map, default: %{})
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :user_id,
      :token_hash,
      :created_at,
      :last_active_at,
      :absolute_expires_at,
      :idle_expires_at,
      :client_meta
    ])
    |> validate_required([
      :user_id,
      :token_hash,
      :created_at,
      :last_active_at,
      :absolute_expires_at,
      :idle_expires_at
    ])
    |> unique_constraint(:token_hash)
  end
end

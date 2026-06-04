defmodule Vigil.Core.Accounts.APIToken do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_tokens" do
    belongs_to(:user, Vigil.Core.Accounts.User)

    field(:name, :string)
    field(:token_hash, :binary)
    field(:scopes, {:array, :string}, default: [])
    field(:last_used_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:inserted_at, :utc_datetime_usec)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:user_id, :name, :token_hash, :scopes, :expires_at])
    |> validate_required([:user_id, :name, :token_hash])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:token_hash)
    |> put_change(:inserted_at, DateTime.utc_now())
  end

  def active?(%__MODULE__{revoked_at: nil, expires_at: nil}), do: true
  def active?(%__MODULE__{revoked_at: revoked_at}) when not is_nil(revoked_at), do: false

  def active?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end
end

defmodule Vigil.Core.Accounts.APITokens do
  import Ecto.Query

  alias Vigil.Repo
  alias Vigil.Core.Accounts.{APIToken, User}

  @doc """
  Mints a new API token for `user`. Returns `{:ok, encoded_token}` where
  `encoded_token` is shown once and never recoverable from storage.
  """
  def mint(%User{} = user, name, opts) when is_binary(name) do
    raw = :crypto.strong_rand_bytes(32)
    encoded = Base.url_encode64(raw, padding: false)
    token_hash = hash(encoded)

    attrs = %{
      user_id: user.id,
      name: name,
      token_hash: token_hash,
      scopes: Keyword.get(opts, :scopes, []),
      expires_at: Keyword.get(opts, :expires_at)
    }

    case %APIToken{} |> APIToken.changeset(attrs) |> Repo.insert() do
      {:ok, _record} -> {:ok, encoded}
      {:error, _} = err -> err
    end
  end

  @doc """
  Looks up an active token by its raw encoded value.
  Returns `{:ok, token_record, user}` or `:error`.
  """
  def lookup(encoded) when is_binary(encoded) do
    token_hash = hash(encoded)

    query =
      from(t in APIToken,
        join: u in User,
        on: u.id == t.user_id,
        where: t.token_hash == ^token_hash and is_nil(t.revoked_at),
        preload: [user: u]
      )

    case Repo.one(query) do
      nil ->
        :error

      token ->
        if APIToken.active?(token) do
          touch_last_used(token)
          {:ok, token, token.user}
        else
          :error
        end
    end
  end

  @doc "Returns all non-revoked tokens for a user, ordered by insertion time."
  def list_for_user(%User{id: user_id}) do
    Repo.all(
      from(t in APIToken,
        where: t.user_id == ^user_id and is_nil(t.revoked_at),
        order_by: [desc: t.inserted_at]
      )
    )
  end

  @doc "Revokes a token by ID. Returns `:ok` or `{:error, :not_found}`."
  def revoke(token_id) do
    case Repo.get(APIToken, token_id) do
      nil ->
        {:error, :not_found}

      token ->
        token
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
        |> Repo.update!()

        :ok
    end
  end

  defp hash(encoded), do: :crypto.hash(:sha256, encoded)

  defp touch_last_used(token) do
    token
    |> Ecto.Changeset.change(last_used_at: DateTime.utc_now())
    |> Repo.update()
  end
end

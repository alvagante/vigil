defmodule Vigil.Core.Accounts do
  import Ecto.Query

  alias Vigil.Repo
  alias Vigil.Core.Accounts.{APITokens, User, Session}

  defdelegate mint_token(user, name, opts), to: APITokens, as: :mint
  defdelegate list_tokens(user), to: APITokens, as: :list_for_user
  defdelegate revoke_token(token_id), to: APITokens, as: :revoke
  defdelegate lookup_token(encoded), to: APITokens, as: :lookup

  @default_tenant_id "00000000-0000-0000-0000-000000000000"
  @session_absolute_ttl_hours 24 * 7
  @session_idle_ttl_hours 8

  def register_user(attrs) do
    %User{tenant_id: @default_tenant_id}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  def authenticate_user(username, password) do
    user = Repo.one(from u in User, where: u.username == ^username and u.auth_source == "local")

    cond do
      user && Argon2.verify_pass(password, user.password_hash) ->
        {:ok, user}

      user ->
        {:error, :invalid_credentials}

      true ->
        Argon2.no_user_verify()
        {:error, :invalid_credentials}
    end
  end

  def create_session(user, opts \\ []) do
    token = :crypto.strong_rand_bytes(32)
    encoded = Base.url_encode64(token, padding: false)
    token_hash = :crypto.hash(:sha256, encoded)

    now = DateTime.utc_now()

    attrs = %{
      user_id: user.id,
      token_hash: token_hash,
      created_at: now,
      last_active_at: now,
      absolute_expires_at: DateTime.add(now, @session_absolute_ttl_hours * 3600),
      idle_expires_at: DateTime.add(now, @session_idle_ttl_hours * 3600),
      client_meta: opts[:client_meta] || %{}
    }

    case %Session{} |> Session.changeset(attrs) |> Repo.insert() do
      {:ok, session} -> {:ok, encoded, session}
      {:error, _} = err -> err
    end
  end

  def fetch_session(token) when is_binary(token) do
    token_hash = :crypto.hash(:sha256, token)

    query =
      from s in Session,
        join: u in User,
        on: u.id == s.user_id,
        where: s.token_hash == ^token_hash,
        preload: [user: u]

    case Repo.one(query) do
      nil -> {:error, :not_found}
      session -> {:ok, session, session.user}
    end
  end

  def get_user_by_username(username) do
    Repo.one(from u in User, where: u.username == ^username)
  end

  def delete_user(%User{is_break_glass: true}), do: {:error, :break_glass_protected}

  def delete_user(%User{} = user) do
    Repo.delete(user)
    :ok
  end

  def delete_session(token) when is_binary(token) do
    token_hash = :crypto.hash(:sha256, token)
    Repo.delete_all(from s in Session, where: s.token_hash == ^token_hash)
    :ok
  end
end

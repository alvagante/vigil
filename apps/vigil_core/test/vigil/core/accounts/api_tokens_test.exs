defmodule Vigil.Core.Accounts.APITokensTest do
  use Vigil.DataCase, async: false

  alias Vigil.Core.{Accounts, Accounts.APITokens}

  defp make_user(name) do
    {:ok, user} = Accounts.register_user(%{username: name, password: "token_test_pass!"})
    user
  end

  describe "mint/3" do
    test "returns an encoded token string shown once" do
      user = make_user("mint_user")
      assert {:ok, token} = APITokens.mint(user, "my-token", [])
      assert is_binary(token)
      assert byte_size(token) > 20
    end

    test "minted token is retrievable by hash" do
      user = make_user("lookup_user")
      {:ok, token} = APITokens.mint(user, "lookup-token", [])
      assert {:ok, _record, ^user} = APITokens.lookup(token)
    end

    test "minted token carries the given name" do
      user = make_user("named_user")
      {:ok, token} = APITokens.mint(user, "ci-token", [])
      {:ok, record, _user} = APITokens.lookup(token)
      assert record.name == "ci-token"
    end
  end

  describe "list_for_user/1" do
    test "returns all active tokens for a user" do
      user = make_user("list_user")
      {:ok, _t1} = APITokens.mint(user, "token-a", [])
      {:ok, _t2} = APITokens.mint(user, "token-b", [])

      tokens = APITokens.list_for_user(user)
      names = Enum.map(tokens, & &1.name)
      assert "token-a" in names
      assert "token-b" in names
    end

    test "does not return tokens belonging to other users" do
      user_a = make_user("list_a_user")
      user_b = make_user("list_b_user")
      {:ok, _} = APITokens.mint(user_a, "token-a", [])

      assert [] = APITokens.list_for_user(user_b)
    end
  end

  describe "revoke/1" do
    test "revoked token is no longer returned by lookup" do
      user = make_user("revoke_user")
      {:ok, token} = APITokens.mint(user, "revoke-me", [])
      {:ok, record, _user} = APITokens.lookup(token)

      assert :ok = APITokens.revoke(record.id)
      assert :error = APITokens.lookup(token)
    end
  end

  describe "lookup/1" do
    test "returns error for unknown token" do
      assert :error = APITokens.lookup("nonexistent-garbage-token")
    end

    test "returns error for revoked token" do
      user = make_user("rev_lookup_user")
      {:ok, token} = APITokens.mint(user, "rev-lookup", [])
      {:ok, record, _} = APITokens.lookup(token)
      APITokens.revoke(record.id)

      assert :error = APITokens.lookup(token)
    end
  end
end

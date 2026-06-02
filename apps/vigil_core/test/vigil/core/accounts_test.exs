defmodule Vigil.Core.AccountsTest do
  use Vigil.DataCase, async: true

  alias Vigil.Core.Accounts

  describe "register_user/1" do
    test "creates a user with an Argon2-hashed password" do
      assert {:ok, user} =
               Accounts.register_user(%{
                 username: "alice",
                 password: "hunter2_correct_horse"
               })

      assert user.username == "alice"
      assert user.auth_source == "local"
      assert user.status == "active"
      assert user.password_hash != nil
      refute user.password_hash == "hunter2_correct_horse"
      assert Argon2.verify_pass("hunter2_correct_horse", user.password_hash)
    end

    test "rejects duplicate username" do
      attrs = %{username: "bob", password: "secret_password_123"}
      assert {:ok, _} = Accounts.register_user(attrs)
      assert {:error, changeset} = Accounts.register_user(attrs)
      assert errors_on(changeset).username != nil
    end

    test "rejects short passwords" do
      assert {:error, changeset} = Accounts.register_user(%{username: "carol", password: "short"})
      assert errors_on(changeset).password != nil
    end
  end

  describe "authenticate_user/2" do
    setup do
      {:ok, user} =
        Accounts.register_user(%{username: "dave", password: "correct_horse_battery"})

      %{user: user}
    end

    test "returns {:ok, user} for valid credentials" do
      assert {:ok, user} = Accounts.authenticate_user("dave", "correct_horse_battery")
      assert user.username == "dave"
    end

    test "returns {:error, :invalid_credentials} for wrong password" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate_user("dave", "wrong_password_here")
    end

    test "returns {:error, :invalid_credentials} for unknown user" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate_user("nobody", "doesnt_matter_password")
    end
  end

  describe "create_session/1 and fetch_session/1" do
    setup do
      {:ok, user} = Accounts.register_user(%{username: "eve", password: "session_test_pass!"})
      %{user: user}
    end

    test "creates a session and returns a one-time token", %{user: user} do
      assert {:ok, token, session} = Accounts.create_session(user)
      assert is_binary(token)
      assert session.user_id == user.id
    end

    test "fetch_session returns user for a valid token", %{user: user} do
      {:ok, token, _session} = Accounts.create_session(user)
      assert {:ok, _session, fetched_user} = Accounts.fetch_session(token)
      assert fetched_user.id == user.id
    end

    test "fetch_session returns {:error, :not_found} for unknown token" do
      assert {:error, :not_found} = Accounts.fetch_session("not_a_real_token_value_xyz")
    end
  end

  describe "delete_session/1" do
    setup do
      {:ok, user} = Accounts.register_user(%{username: "frank", password: "logout_test_pass!"})
      {:ok, token, _session} = Accounts.create_session(user)
      %{token: token}
    end

    test "token cannot be fetched after logout", %{token: token} do
      assert :ok = Accounts.delete_session(token)
      assert {:error, :not_found} = Accounts.fetch_session(token)
    end
  end
end

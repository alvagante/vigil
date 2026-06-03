defmodule VigilWeb.TokenAuthPlugTest do
  use VigilWeb.LiveCase, async: true

  alias Vigil.Core.Accounts
  alias VigilWeb.TokenAuthPlug

  defp make_user(name) do
    {:ok, user} = Accounts.register_user(%{username: name, password: "plugtest_pass!"})
    user
  end

  describe "call/2" do
    test "assigns current_user from valid Bearer token" do
      user = make_user("tok_auth_user")
      {:ok, token} = Accounts.mint_token(user, "ci-token", [])

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> TokenAuthPlug.call([])

      assert conn.assigns[:current_user].id == user.id
    end

    test "assigns auth_source :token for token-authenticated requests" do
      user = make_user("tok_source_user")
      {:ok, token} = Accounts.mint_token(user, "source-token", [])

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> TokenAuthPlug.call([])

      assert conn.assigns[:auth_source] == :token
    end

    test "does not assign current_user for an invalid token" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer bad-token-value")
        |> TokenAuthPlug.call([])

      refute Map.has_key?(conn.assigns, :current_user)
    end

    test "passes through when no Authorization header is present" do
      conn = build_conn() |> TokenAuthPlug.call([])
      refute Map.has_key?(conn.assigns, :current_user)
    end

    test "does not override an existing current_user (session wins)" do
      user = make_user("tok_existing_user")
      other_user = make_user("tok_other_user")
      {:ok, token} = Accounts.mint_token(user, "existing-token", [])

      conn =
        build_conn()
        |> assign(:current_user, other_user)
        |> put_req_header("authorization", "Bearer #{token}")
        |> TokenAuthPlug.call([])

      assert conn.assigns[:current_user].id == other_user.id
    end
  end
end

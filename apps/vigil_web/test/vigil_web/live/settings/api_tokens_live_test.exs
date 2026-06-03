defmodule VigilWeb.Live.Settings.APITokensLiveTest do
  use VigilWeb.LiveCase, async: true

  alias Vigil.Core.Accounts

  describe "GET /settings/tokens" do
    test "authenticated user sees their tokens page", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, _lv, html} = live(conn, ~p"/settings/tokens")
      assert html =~ "API Tokens"
    end

    test "shows minted tokens for the user", %{conn: conn} do
      user = user_fixture()
      Accounts.mint_token(user, "my-ci-token", [])
      conn = log_in_user(conn, user)

      {:ok, _lv, html} = live(conn, ~p"/settings/tokens")
      assert html =~ "my-ci-token"
    end

    test "does not show tokens belonging to other users", %{conn: conn} do
      user = user_fixture()
      other = user_fixture()
      Accounts.mint_token(other, "other-token", [])
      conn = log_in_user(conn, user)

      {:ok, _lv, html} = live(conn, ~p"/settings/tokens")
      refute html =~ "other-token"
    end
  end

  describe "minting a new token" do
    test "submitting a name creates the token and reveals it once", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/settings/tokens")

      html =
        lv
        |> form("#mint-token-form", token: %{name: "automation-key"})
        |> render_submit()

      assert html =~ "automation-key"
      assert html =~ "Copy it now"
    end
  end

  describe "revoking a token" do
    test "revoking a token removes it from the list", %{conn: conn} do
      user = user_fixture()
      Accounts.mint_token(user, "to-revoke", [])
      conn = log_in_user(conn, user)

      {:ok, lv, html} = live(conn, ~p"/settings/tokens")
      assert html =~ "to-revoke"

      tokens = Accounts.list_tokens(user)
      token = Enum.find(tokens, &(&1.name == "to-revoke"))

      html =
        lv
        |> element("[phx-click=revoke][phx-value-id=\"#{token.id}\"]")
        |> render_click()

      refute html =~ "to-revoke"
    end
  end
end

defmodule VigilWeb.LiveCase do
  @moduledoc """
  Test case template for LiveView tests that also need database access.
  Combines the Ecto sandbox setup with Phoenix.LiveViewTest helpers and
  the `~p` verified-routes sigil.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use VigilWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Vigil.DataCase
      import VigilWeb.LiveCase

      @endpoint VigilWeb.Endpoint
    end
  end

  setup tags do
    Vigil.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Registers a user and stamps a valid session token into the conn's plug session,
  so that SessionPlug and LiveAuth both see an authenticated user.
  """
  def log_in_user(conn, user) do
    {:ok, token, _session} = Vigil.Core.Accounts.create_session(user)
    Plug.Test.init_test_session(conn, %{"_vigil_token" => token})
  end

  @doc "Creates a test user with a unique username."
  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, user} =
      Vigil.Core.Accounts.register_user(
        Map.merge(%{username: "test_user_#{n}", password: "test_password_123!"}, attrs)
      )

    user
  end
end

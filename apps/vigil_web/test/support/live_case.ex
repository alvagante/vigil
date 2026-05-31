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

      @endpoint VigilWeb.Endpoint
    end
  end

  setup tags do
    Vigil.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end

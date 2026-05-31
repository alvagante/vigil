defmodule VigilWeb.Plugs.Health do
  @moduledoc """
  Lightweight liveness endpoint at `/_health`.

  Returns the running release version as JSON without touching the database or
  LiveView, so it is safe to use as a container `HEALTHCHECK` and as the CI
  smoke target against the released artefact.
  """

  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/_health"} = conn, _opts) do
    body = Jason.encode!(%{status: "ok", version: version()})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
    |> halt()
  end

  def call(conn, _opts), do: conn

  defp version do
    case Application.spec(:vigil_web, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end
end

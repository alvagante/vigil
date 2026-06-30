defmodule VigilWeb.HealthControllerTest do
  use VigilWeb.ConnCase, async: true

  describe "GET /_health" do
    test "returns 200 with status ok and version string without authentication", %{conn: conn} do
      conn = get(conn, "/_health")
      body = json_response(conn, 200)
      assert body["status"] == "ok"
      assert is_binary(body["version"]) and body["version"] != ""
    end
  end
end

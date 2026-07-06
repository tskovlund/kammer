defmodule KammerWeb.HealthControllerTest do
  use KammerWeb.ConnCase, async: true

  test "answers ok when the database is reachable", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert text_response(conn, 200) == "ok"
  end
end

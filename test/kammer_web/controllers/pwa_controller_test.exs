defmodule KammerWeb.PwaControllerTest do
  # async: false — these tests point :pwa_client_root at per-test
  # fixtures via the application environment, which is global.
  use KammerWeb.ConnCase, async: false

  @moduletag :tmp_dir

  defp point_client_root_at(path) do
    Application.put_env(:kammer, :pwa_client_root, path)
    on_exit(fn -> Application.delete_env(:kammer, :pwa_client_root) end)
  end

  describe "without a built client bundle (plain mix phx.server)" do
    setup %{tmp_dir: tmp_dir} do
      # A directory that exists but holds no index.html — same shape as a
      # checkout where the client was never built.
      point_client_root_at(tmp_dir)
      :ok
    end

    test "GET /app answers a plain-text explanation, not a 500", %{conn: conn} do
      conn = get(conn, "/app")

      assert response(conn, 404) =~ "not bundled"
      assert response_content_type(conn, :text)
    end

    test "deep client routes get the same graceful answer", %{conn: conn} do
      conn = get(conn, "/app/sign-in/some-token")

      assert response(conn, 404) =~ "pnpm dev"
    end
  end

  describe "with a built client bundle" do
    setup %{tmp_dir: tmp_dir} do
      File.write!(
        Path.join(tmp_dir, "index.html"),
        "<!doctype html><html><body>kammer-pwa-fixture</body></html>"
      )

      point_client_root_at(tmp_dir)
      :ok
    end

    test "GET /app serves index.html", %{conn: conn} do
      conn = get(conn, "/app")

      assert html_response(conn, 200) =~ "kammer-pwa-fixture"
    end

    test "client-side routes fall back to index.html so deep links work",
         %{conn: conn} do
      # The magic-link landing route the PWA owns (ADR 0024).
      conn = get(conn, "/app/sign-in/abc123")

      assert html_response(conn, 200) =~ "kammer-pwa-fixture"
    end

    test "the fallback document carries its own CSP and never caches stale",
         %{conn: conn} do
      conn = get(conn, "/app")

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'self'"
      assert csp =~ "connect-src 'self' https: wss:"
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end

    test "the PWA scope shadows nothing outside its base path", %{conn: conn} do
      # Liveness probe.
      assert text_response(get(conn, "/healthz"), 200) == "ok"

      # JSON API.
      assert %{"instance_name" => _} = json_response(get(conn, "/api/v1/instance"), 200)

      # LiveView keeps "/" until the removal cut (#187).
      assert html_response(get(conn, "/"), 200)
    end
  end
end

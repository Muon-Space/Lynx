defmodule LynxWeb.OPABundleControllerTest do
  @moduledoc """
  Bundle endpoint auth + content (issue #38). Two auth paths exercised:
  the env-var token (Helm-managed case) and the DB token (admin-minted).
  ETag short-circuit verified to keep OPA polling cheap.
  """
  use LynxWeb.ConnCase, async: false

  alias Lynx.Context.OPABundleTokenContext

  setup do
    # Reset env to a known state per test so the env-var path is opt-in.
    on_exit(fn -> Application.delete_env(:lynx, :opa_bundle_token) end)
    :ok
  end

  describe "auth" do
    test "no Authorization header returns 401", %{conn: conn} do
      conn = get(conn, "/api/v1/opa/bundle.tar.gz")
      assert json_response(conn, 401)["errorMessage"] =~ "Missing"
    end

    test "wrong bearer returns 401", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong")
        |> get("/api/v1/opa/bundle.tar.gz")

      assert json_response(conn, 401)["errorMessage"] =~ "Invalid"
    end

    test "matching env-var token returns 200", %{conn: conn} do
      Application.put_env(:lynx, :opa_bundle_token, "env-secret")

      conn =
        conn
        |> put_req_header("authorization", "Bearer env-secret")
        |> get("/api/v1/opa/bundle.tar.gz")

      assert response(conn, 200)
      assert response_content_type(conn, :gzip) =~ "application/gzip"
    end

    test "active DB token returns 200", %{conn: conn} do
      {:ok, %{token: token}} = OPABundleTokenContext.generate_token("primary")

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/v1/opa/bundle.tar.gz")

      assert response(conn, 200)
    end

    test "revoked DB token returns 401", %{conn: conn} do
      {:ok, %{uuid: uuid, token: token}} = OPABundleTokenContext.generate_token("p")
      {:ok, _} = OPABundleTokenContext.revoke_token_by_uuid(uuid)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/v1/opa/bundle.tar.gz")

      assert json_response(conn, 401)
    end
  end

  describe "content" do
    setup %{conn: conn} do
      Application.put_env(:lynx, :opa_bundle_token, "env-secret")
      {:ok, conn: put_req_header(conn, "authorization", "Bearer env-secret")}
    end

    test "returns ETag header", %{conn: conn} do
      conn = get(conn, "/api/v1/opa/bundle.tar.gz")
      assert [_etag] = get_resp_header(conn, "etag")
    end

    test "If-None-Match matching ETag returns 304", %{conn: conn} do
      first = get(conn, "/api/v1/opa/bundle.tar.gz")
      [etag] = get_resp_header(first, "etag")

      second =
        conn
        |> put_req_header("if-none-match", etag)
        |> get("/api/v1/opa/bundle.tar.gz")

      assert second.status == 304
      assert response(second, 304) == ""
      # ETag should still be present on 304 responses for OPA to update its cache.
      assert [^etag] = get_resp_header(second, "etag")
    end

    test "body is a valid gzipped tarball with the manifest", %{conn: conn} do
      conn = get(conn, "/api/v1/opa/bundle.tar.gz")
      raw = :zlib.gunzip(response(conn, 200))

      assert {:ok, files} = :erl_tar.extract({:binary, raw}, [:memory])
      manifest = Enum.find(files, fn {n, _} -> List.to_string(n) == ".manifest" end)
      assert manifest != nil
    end
  end
end

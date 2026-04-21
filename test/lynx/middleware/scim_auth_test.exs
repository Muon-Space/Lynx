# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Middleware.SCIMAuthMiddlewareTest do
  use LynxWeb.ConnCase

  alias Lynx.Context.SCIMTokenContext
  alias Lynx.Service.Settings

  setup do
    Settings.upsert_config("scim_enabled", "true")

    {:ok, token_result} = SCIMTokenContext.generate_token("test token")

    on_exit(fn ->
      Settings.upsert_config("scim_enabled", "false")
    end)

    {:ok, token: token_result.token}
  end

  test "halts with 401 when no Authorization header", %{conn: conn} do
    conn = Lynx.Middleware.SCIMAuthMiddleware.call(conn, nil)
    assert conn.halted
    assert conn.status == 401
  end

  test "halts with 401 when token is wrong", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer wrong-token")
      |> Lynx.Middleware.SCIMAuthMiddleware.call(nil)

    assert conn.halted
    assert conn.status == 401
  end

  test "passes through with valid token", %{conn: conn, token: token} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> Lynx.Middleware.SCIMAuthMiddleware.call(nil)

    refute conn.halted
    assert conn.assigns[:scim_authenticated] == true
  end

  test "halts with 404 when SCIM is disabled", %{conn: conn, token: token} do
    Settings.upsert_config("scim_enabled", "false")

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> Lynx.Middleware.SCIMAuthMiddleware.call(nil)

    assert conn.halted
    assert conn.status == 404
  end
end

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Middleware.SCIMAuthMiddlewareTest do
  use LynxWeb.ConnCase

  @scim_token "test-scim-token-middleware"

  setup do
    Application.put_env(:lynx, :scim_enabled, true)
    Application.put_env(:lynx, :scim_bearer_token, @scim_token)

    on_exit(fn ->
      Application.put_env(:lynx, :scim_enabled, false)
      Application.put_env(:lynx, :scim_bearer_token, nil)
    end)

    :ok
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

  test "passes through with valid token", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@scim_token}")
      |> Lynx.Middleware.SCIMAuthMiddleware.call(nil)

    refute conn.halted
    assert conn.assigns[:scim_authenticated] == true
  end

  test "halts with 404 when SCIM is disabled", %{conn: conn} do
    Application.put_env(:lynx, :scim_enabled, false)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@scim_token}")
      |> Lynx.Middleware.SCIMAuthMiddleware.call(nil)

    assert conn.halted
    assert conn.status == 404
  end
end

defmodule LynxWeb.SCIMRequestLoggingTest do
  @moduledoc """
  Pinning that requests hitting `/scim/v2/*` actually emit container
  logs (the "Incoming METHOD Request to ..." line from
  `Lynx.Middleware.Logger`). In production we observed zero `/scim`
  hits in 48h of pod logs even though Okta's "Test Connector
  Configuration" succeeded — meaning the requests reach the controller
  but the log line never makes it to stdout.

  Compares against the `/api/v1/*` path, which we know logs correctly.
  Both pipelines plug `Lynx.Middleware.Logger`, so a divergence here
  is a router-config bug.
  """
  use LynxWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Lynx.Context.SCIMTokenContext
  alias Lynx.Service.Settings

  setup_all do
    # config/test.exs sets logger level to :warning to silence noise.
    # Bump it back to :info for this file so capture_log/1 sees the
    # `Logger.info(...)` calls from `Lynx.Middleware.Logger`.
    prior = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prior) end)
    :ok
  end

  setup %{conn: conn} do
    post(conn, "/action/install", %{
      app_name: "Lynx",
      app_url: "https://lynx.com",
      app_email: "hello@lynx.com",
      admin_name: "Admin",
      admin_email: "admin@example.com",
      admin_password: "password123"
    })

    Settings.upsert_config("scim_enabled", "true")
    {:ok, scim_token} = SCIMTokenContext.generate_token("logging-test")

    on_exit(fn -> Settings.upsert_config("scim_enabled", "false") end)

    {:ok, conn: conn, scim_token: scim_token.token}
  end

  defp scim_conn(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/scim+json")
  end

  test "GET /scim/v2/ServiceProviderConfig produces an Incoming-Request log line",
       %{conn: conn, scim_token: scim_token} do
    log =
      capture_log([level: :info], fn ->
        conn
        |> scim_conn(scim_token)
        |> get("/scim/v2/ServiceProviderConfig")
      end)

    assert log =~ "Incoming GET Request to /scim/v2/ServiceProviderConfig",
           "Lynx.Middleware.Logger did not log this SCIM request to the container — captured: #{inspect(log)}"
  end

  test "POST /scim/v2/Users produces an Incoming-Request log line",
       %{conn: conn, scim_token: scim_token} do
    log =
      capture_log([level: :info], fn ->
        conn
        |> scim_conn(scim_token)
        |> post("/scim/v2/Users", %{
          "userName" => "logging_test@example.com",
          "name" => %{"formatted" => "Logging Test"},
          "externalId" => "scim-log-test"
        })
      end)

    assert log =~ "Incoming POST Request to /scim/v2/Users",
           "Lynx.Middleware.Logger did not log this SCIM POST to the container — captured: #{inspect(log)}"
  end

  test "/_health (`:pub` pipeline) logs correctly — control to prove the harness sees Logger.info",
       %{conn: conn} do
    # Sanity check that the harness CAN observe the middleware. Picked
    # a route guaranteed to match (200, not 404) — the middleware
    # only runs after the router matches a route.
    log =
      capture_log([level: :info], fn ->
        get(conn, "/_health")
      end)

    assert log =~ "Incoming GET Request to /_health"
  end
end

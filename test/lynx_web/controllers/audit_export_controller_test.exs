defmodule LynxWeb.AuditExportControllerTest do
  use LynxWeb.ConnCase, async: false

  alias Lynx.Context.{AuditContext, UserContext}

  setup %{conn: conn} do
    install_admin_and_get_api_key(conn)
    admin = UserContext.get_user_by_email("john@example.com")
    {:ok, conn: conn, admin: admin}
  end

  describe "GET /admin/audit/export.csv" do
    test "super: streams CSV with header + one row per event", %{conn: conn, admin: admin} do
      AuditContext.log_user(admin, "created", "project", "p1", "Alpha")
      AuditContext.log_user(admin, "deleted", "project", "p2", "Beta")

      conn = log_in_admin(conn, admin) |> get("/admin/audit/export.csv")

      assert response_content_type(conn, :csv) =~ "text/csv"
      body = response(conn, 200)
      lines = String.split(body, "\r\n", trim: true)

      assert hd(lines) =~ "id,action,resource_type"
      assert Enum.any?(tl(lines), &String.contains?(&1, "Alpha"))
      assert Enum.any?(tl(lines), &String.contains?(&1, "Beta"))
    end

    test "honors filter query params", %{conn: conn, admin: admin} do
      AuditContext.log_user(admin, "created", "project", "p1", "Alpha")
      AuditContext.log_user(admin, "deleted", "project", "p2", "Beta")

      conn = log_in_admin(conn, admin) |> get("/admin/audit/export.csv?action=created")

      body = response(conn, 200)
      assert body =~ "Alpha"
      refute body =~ "Beta"
    end

    test "non-super: 403", %{conn: conn} do
      n = System.unique_integer([:positive])

      app_key = Lynx.Service.Settings.get_config("app_key", "")
      api_key = Lynx.Service.AuthService.get_random_salt(20)

      {:ok, regular} =
        UserContext.create_user(
          UserContext.new_user(%{
            email: "regular-#{n}@example.com",
            name: "Regular #{n}",
            password_hash: Lynx.Service.AuthService.hash_password("password123", app_key),
            verified: true,
            last_seen: DateTime.utc_now() |> DateTime.truncate(:second),
            role: "regular",
            api_key: api_key
          })
        )

      conn = log_in_admin(conn, regular) |> get("/admin/audit/export.csv")

      assert response(conn, 403)
    end
  end

  # The CSV download uses the LV cookie session (not API key auth) so we
  # mirror the LiveView login flow here.
  defp log_in_admin(conn, user) do
    {:success, session} = Lynx.Service.AuthService.authenticate(user.id)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:uid, user.id)
    |> Plug.Conn.put_session(:token, session.value)
  end
end

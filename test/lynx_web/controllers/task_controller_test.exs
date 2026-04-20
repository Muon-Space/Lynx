defmodule LynxWeb.TaskControllerTest do
  use LynxWeb.ConnCase

  setup %{conn: conn} do
    api_key = install_admin_and_get_api_key(conn)
    {:ok, conn: conn, api_key: api_key}
  end

  describe "auth" do
    test "GET task without API key returns 403", %{conn: conn} do
      # task_controller uses :regular_user plug which returns 403 (Forbidden)
      # rather than 401 when not logged in
      conn = get(conn, "/api/v1/task/00000000-0000-0000-0000-000000000000")
      assert response(conn, 403)
    end
  end

  describe "index" do
    test "returns 404 for unknown task uuid", %{conn: conn, api_key: api_key} do
      conn =
        conn |> with_api_key(api_key) |> get("/api/v1/task/00000000-0000-0000-0000-000000000000")

      assert response(conn, 404)
    end
  end
end

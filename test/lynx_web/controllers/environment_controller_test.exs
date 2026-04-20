defmodule LynxWeb.EnvironmentControllerTest do
  use LynxWeb.ConnCase

  setup %{conn: conn} do
    api_key = install_admin_and_get_api_key(conn)
    {:ok, conn: conn, api_key: api_key}
  end

  defp create_team_via_api(api_key) do
    n = System.unique_integer([:positive])
    admin = Lynx.Context.UserContext.get_user_by_email("john@example.com")

    conn =
      build_conn()
      |> with_api_key(api_key)
      |> post("/api/v1/team", %{
        name: "T#{n}",
        slug: "t-#{n}",
        description: "for env tests",
        members: [admin.uuid]
      })

    json_response(conn, 201)["id"]
  end

  defp create_project_via_api(api_key) do
    team_uuid = create_team_via_api(api_key)
    n = System.unique_integer([:positive])

    conn =
      build_conn()
      |> with_api_key(api_key)
      |> post("/api/v1/project", %{
        name: "P#{n}",
        slug: "p-#{n}",
        description: "for env tests",
        team_ids: [team_uuid]
      })

    json_response(conn, 201)["id"]
  end

  describe "auth" do
    test "GET environment list without API key returns 403", %{conn: conn} do
      conn = get(conn, "/api/v1/project/some-uuid/environment")
      assert response(conn, 403)
    end
  end

  describe "list" do
    test "returns environments for a project", %{conn: conn, api_key: api_key} do
      project_uuid = create_project_via_api(api_key)

      conn =
        conn |> with_api_key(api_key) |> get("/api/v1/project/#{project_uuid}/environment")

      body = json_response(conn, 200)
      assert is_list(body["environments"])
    end
  end

  describe "create" do
    test "creates an environment under the project", %{conn: conn, api_key: api_key} do
      project_uuid = create_project_via_api(api_key)

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/project/#{project_uuid}/environment", %{
          name: "Production",
          slug: "prod",
          username: "u1",
          secret: "s1"
        })

      body = json_response(conn, 201)
      assert body["name"] == "Production"
      assert body["slug"] == "prod"
    end

    test "returns 400 when slug is missing", %{conn: conn, api_key: api_key} do
      project_uuid = create_project_via_api(api_key)

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/project/#{project_uuid}/environment", %{name: "x"})

      assert response(conn, 400)
    end
  end

  describe "index" do
    test "404 for unknown env uuid", %{conn: conn, api_key: api_key} do
      project_uuid = create_project_via_api(api_key)

      conn =
        conn
        |> with_api_key(api_key)
        |> get("/api/v1/project/#{project_uuid}/environment/00000000-0000-0000-0000-000000000000")

      assert response(conn, 404)
    end
  end
end

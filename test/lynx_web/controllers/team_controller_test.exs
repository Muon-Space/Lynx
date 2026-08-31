defmodule LynxWeb.TeamControllerTest do
  use LynxWeb.ConnCase

  setup %{conn: conn} do
    api_key = install_admin_and_get_api_key(conn)
    {:ok, conn: conn, api_key: api_key}
  end

  defp create_team(api_key, attrs) do
    build_conn()
    |> with_api_key(api_key)
    |> post("/api/v1/team", attrs)
    |> json_response(201)
    |> Map.get("id")
  end

  describe "auth" do
    test "GET /api/v1/team without API key returns 403", %{conn: conn} do
      conn = get(conn, "/api/v1/team")
      assert response(conn, 403)
    end
  end

  describe "list" do
    test "returns teams list", %{conn: conn, api_key: api_key} do
      conn = conn |> with_api_key(api_key) |> get("/api/v1/team")
      body = json_response(conn, 200)
      assert is_list(body["teams"])
    end
  end

  describe "list filtered by slug" do
    test "returns only the matching team", %{conn: _conn, api_key: api_key} do
      admin = Lynx.Context.UserContext.get_user_by_email("john@example.com")

      create_team(api_key, %{
        name: "Platform",
        slug: "platform",
        description: "platform team",
        members: [admin.uuid]
      })

      create_team(api_key, %{
        name: "Other",
        slug: "other",
        description: "other team",
        members: [admin.uuid]
      })

      body =
        build_conn()
        |> with_api_key(api_key)
        |> get("/api/v1/team", %{slug: "platform"})
        |> json_response(200)

      assert length(body["teams"]) == 1
      assert hd(body["teams"])["slug"] == "platform"
      assert body["_metadata"]["totalCount"] == 1
    end

    test "returns an empty list when nothing matches", %{conn: _conn, api_key: api_key} do
      body =
        build_conn()
        |> with_api_key(api_key)
        |> get("/api/v1/team", %{slug: "does-not-exist"})
        |> json_response(200)

      assert body["teams"] == []
      assert body["_metadata"]["totalCount"] == 0
    end

    test "an absent slug leaves the unfiltered listing alone", %{conn: _conn, api_key: api_key} do
      admin = Lynx.Context.UserContext.get_user_by_email("john@example.com")

      create_team(api_key, %{
        name: "Platform",
        slug: "platform",
        description: "platform team",
        members: [admin.uuid]
      })

      body =
        build_conn()
        |> with_api_key(api_key)
        |> get("/api/v1/team")
        |> json_response(200)

      assert body["_metadata"]["totalCount"] == Lynx.Context.TeamContext.count_teams()
      assert Enum.any?(body["teams"], &(&1["slug"] == "platform"))
    end

    test "a regular user cannot see a team they do not belong to", %{
      conn: _conn,
      api_key: api_key
    } do
      admin = Lynx.Context.UserContext.get_user_by_email("john@example.com")

      create_team(api_key, %{
        name: "Hidden",
        slug: "hidden",
        description: "admin only",
        members: [admin.uuid]
      })

      {_user, regular_key} = create_regular_user_with_api_key()

      body =
        build_conn()
        |> with_api_key(regular_key)
        |> get("/api/v1/team", %{slug: "hidden"})
        |> json_response(200)

      assert body["teams"] == []
      assert body["_metadata"]["totalCount"] == 0
    end

    test "a regular user can look up a team they belong to", %{conn: _conn, api_key: api_key} do
      {user, regular_key} = create_regular_user_with_api_key()

      team_uuid =
        create_team(api_key, %{
          name: "Mine",
          slug: "mine",
          description: "their team",
          members: [user.uuid]
        })

      body =
        build_conn()
        |> with_api_key(regular_key)
        |> get("/api/v1/team", %{slug: "mine"})
        |> json_response(200)

      assert length(body["teams"]) == 1
      assert hd(body["teams"])["id"] == team_uuid
      assert body["_metadata"]["totalCount"] == 1
    end
  end

  describe "create" do
    test "creates a team", %{conn: conn, api_key: api_key} do
      # team_controller requires non-empty `members`; use the admin user's uuid
      admin = Lynx.Context.UserContext.get_user_by_email("john@example.com")

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/team", %{
          name: "Platform",
          slug: "platform",
          description: "Platform team",
          members: [admin.uuid]
        })

      body = json_response(conn, 201)
      assert body["name"] == "Platform"
      assert body["slug"] == "platform"
    end

    test "returns 400 when name is missing", %{conn: conn, api_key: api_key} do
      conn = conn |> with_api_key(api_key) |> post("/api/v1/team", %{slug: "x"})
      assert response(conn, 400)
    end
  end

  describe "index/delete" do
    test "404 for unknown uuid on get", %{conn: conn, api_key: api_key} do
      conn =
        conn |> with_api_key(api_key) |> get("/api/v1/team/00000000-0000-0000-0000-000000000000")

      assert response(conn, 404)
    end

    test "404 for unknown uuid on delete", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> delete("/api/v1/team/00000000-0000-0000-0000-000000000000")

      assert response(conn, 404)
    end
  end
end

defmodule LynxWeb.WorkspaceControllerTest do
  use LynxWeb.ConnCase

  alias Lynx.Context.ProjectContext
  alias Lynx.Context.WorkspaceContext

  setup %{conn: conn} do
    api_key = install_admin_and_get_api_key(conn)
    {:ok, conn: conn, api_key: api_key}
  end

  defp create_workspace(conn, api_key, attrs) do
    build_conn()
    |> with_api_key(api_key)
    |> post("/api/v1/workspace", attrs)
    |> json_response(201)
    |> Map.get("id")
    |> then(fn uuid -> {conn, uuid} end)
  end

  describe "auth" do
    test "GET /api/v1/workspace without API key returns 403", %{conn: conn} do
      conn = get(conn, "/api/v1/workspace")
      assert response(conn, 403)
    end
  end

  describe "permissions" do
    test "regular user can list workspaces", %{conn: conn} do
      {_user, regular_key} = create_regular_user_with_api_key()

      conn = conn |> with_api_key(regular_key) |> get("/api/v1/workspace")

      assert is_list(json_response(conn, 200)["workspaces"])
    end

    test "regular user cannot create a workspace", %{conn: conn} do
      {_user, regular_key} = create_regular_user_with_api_key()

      conn =
        conn
        |> with_api_key(regular_key)
        |> post("/api/v1/workspace", %{name: "Nope", slug: "nope", description: "nope"})

      assert response(conn, 403)
    end

    test "regular user cannot get, update or delete a workspace", %{conn: conn, api_key: api_key} do
      {_conn, uuid} =
        create_workspace(conn, api_key, %{
          name: "Locked",
          slug: "locked",
          description: "super only"
        })

      {_user, regular_key} = create_regular_user_with_api_key()

      assert response(
               build_conn() |> with_api_key(regular_key) |> get("/api/v1/workspace/#{uuid}"),
               403
             )

      assert response(
               build_conn()
               |> with_api_key(regular_key)
               |> put("/api/v1/workspace/#{uuid}", %{
                 name: "Hacked",
                 slug: "locked",
                 description: "nope"
               }),
               403
             )

      assert response(
               build_conn() |> with_api_key(regular_key) |> delete("/api/v1/workspace/#{uuid}"),
               403
             )
    end

    test "regular user only sees workspaces holding their team's projects", %{
      conn: conn,
      api_key: api_key
    } do
      create_workspace(conn, api_key, %{
        name: "Hidden",
        slug: "hidden",
        description: "no projects"
      })

      {_user, regular_key} = create_regular_user_with_api_key()

      body =
        build_conn()
        |> with_api_key(regular_key)
        |> get("/api/v1/workspace")
        |> json_response(200)

      assert body["workspaces"] == []
      assert body["_metadata"]["totalCount"] == 0
    end

    test "regular user can paginate", %{conn: _conn} do
      # The regular-user branch slices in memory rather than in the database,
      # and query params arrive as strings, so this combination used to raise.
      # The super-user branch goes through Ecto, which tolerates the strings —
      # which is why the list tests below did not catch it.
      {_user, regular_key} = create_regular_user_with_api_key()

      body =
        build_conn()
        |> with_api_key(regular_key)
        |> get("/api/v1/workspace", %{limit: 1, offset: 0})
        |> json_response(200)

      assert body["_metadata"]["limit"] == 1
      assert body["_metadata"]["offset"] == 0
    end
  end

  describe "list" do
    test "returns workspaces list", %{conn: conn, api_key: api_key} do
      create_workspace(conn, api_key, %{
        name: "Platform",
        slug: "platform",
        description: "platform workspace"
      })

      body = conn |> with_api_key(api_key) |> get("/api/v1/workspace") |> json_response(200)

      assert is_list(body["workspaces"])
      assert Enum.any?(body["workspaces"], &(&1["slug"] == "platform"))
    end

    test "reports totalCount and honours limit/offset", %{conn: conn, api_key: api_key} do
      # The `create_workspaces` migration seeds a `default` workspace, so the
      # totals below account for it alongside the three created here.
      for i <- 1..3 do
        create_workspace(conn, api_key, %{
          name: "WS #{i}",
          slug: "ws-#{i}",
          description: "workspace #{i}"
        })
      end

      total = WorkspaceContext.count_workspaces()

      body =
        conn
        |> with_api_key(api_key)
        |> get("/api/v1/workspace", %{limit: 2, offset: 0})
        |> json_response(200)

      assert length(body["workspaces"]) == 2
      assert body["_metadata"]["limit"] == 2
      assert body["_metadata"]["offset"] == 0
      assert body["_metadata"]["totalCount"] == total

      page_two =
        build_conn()
        |> with_api_key(api_key)
        |> get("/api/v1/workspace", %{limit: 2, offset: 2})
        |> json_response(200)

      first_page_ids = Enum.map(body["workspaces"], & &1["id"])
      second_page_ids = Enum.map(page_two["workspaces"], & &1["id"])

      assert first_page_ids != second_page_ids
      assert Enum.empty?(first_page_ids -- (first_page_ids -- second_page_ids))
    end
  end

  describe "create" do
    test "creates a workspace", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/workspace", %{
          name: "Platform",
          slug: "platform",
          description: "Platform workspace"
        })

      body = json_response(conn, 201)
      assert body["name"] == "Platform"
      assert body["slug"] == "platform"
      assert body["description"] == "Platform workspace"
      assert body["projectsCount"] == 0
      assert is_binary(body["id"])
    end

    test "returns 400 when name is missing", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/workspace", %{slug: "x", description: "y"})

      assert response(conn, 400)
    end

    test "returns 400 when slug is missing", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/workspace", %{name: "No Slug", description: "y"})

      assert response(conn, 400)
    end

    test "returns 400 for a duplicate slug", %{conn: conn, api_key: api_key} do
      create_workspace(conn, api_key, %{
        name: "Platform",
        slug: "platform",
        description: "first"
      })

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/workspace", %{
          name: "Platform Two",
          slug: "platform",
          description: "second"
        })

      assert json_response(conn, 400)["errorMessage"] == "Workspace slug is already used"
    end
  end

  describe "index" do
    test "returns a workspace by uuid", %{conn: conn, api_key: api_key} do
      {_conn, uuid} =
        create_workspace(conn, api_key, %{
          name: "Platform",
          slug: "platform",
          description: "Platform workspace"
        })

      body =
        conn |> with_api_key(api_key) |> get("/api/v1/workspace/#{uuid}") |> json_response(200)

      assert body["id"] == uuid
      assert body["slug"] == "platform"
    end

    test "404 for unknown uuid on get", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> get("/api/v1/workspace/00000000-0000-0000-0000-000000000000")

      assert response(conn, 404)
    end
  end

  describe "update" do
    test "updates a workspace", %{conn: conn, api_key: api_key} do
      {_conn, uuid} =
        create_workspace(conn, api_key, %{
          name: "Platform",
          slug: "platform",
          description: "Platform workspace"
        })

      body =
        conn
        |> with_api_key(api_key)
        |> put("/api/v1/workspace/#{uuid}", %{
          name: "Platform Renamed",
          slug: "platform-renamed",
          description: "Renamed workspace"
        })
        |> json_response(200)

      assert body["id"] == uuid
      assert body["name"] == "Platform Renamed"
      assert body["slug"] == "platform-renamed"
    end

    test "keeping the same slug is allowed", %{conn: conn, api_key: api_key} do
      {_conn, uuid} =
        create_workspace(conn, api_key, %{
          name: "Platform",
          slug: "platform",
          description: "Platform workspace"
        })

      body =
        conn
        |> with_api_key(api_key)
        |> put("/api/v1/workspace/#{uuid}", %{
          name: "Platform Renamed",
          slug: "platform",
          description: "Platform workspace"
        })
        |> json_response(200)

      assert body["slug"] == "platform"
    end

    test "returns 400 when taking another workspace's slug", %{conn: conn, api_key: api_key} do
      create_workspace(conn, api_key, %{name: "One", slug: "one", description: "first"})

      {_conn, uuid} =
        create_workspace(conn, api_key, %{name: "Two", slug: "two", description: "second"})

      conn =
        conn
        |> with_api_key(api_key)
        |> put("/api/v1/workspace/#{uuid}", %{
          name: "Two",
          slug: "one",
          description: "second"
        })

      assert json_response(conn, 400)["errorMessage"] == "Workspace slug is already used"
    end

    test "404 for unknown uuid on update", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> put("/api/v1/workspace/00000000-0000-0000-0000-000000000000", %{
          name: "Ghost",
          slug: "ghost",
          description: "nope"
        })

      assert response(conn, 404)
    end
  end

  describe "delete" do
    test "deletes an empty workspace", %{conn: conn, api_key: api_key} do
      {_conn, uuid} =
        create_workspace(conn, api_key, %{
          name: "Empty",
          slug: "empty",
          description: "no projects"
        })

      conn = conn |> with_api_key(api_key) |> delete("/api/v1/workspace/#{uuid}")

      assert response(conn, 204)
      assert WorkspaceContext.get_workspace_by_uuid(uuid) == nil
    end

    test "refuses to delete a workspace that still has projects", %{conn: conn, api_key: api_key} do
      {_conn, uuid} =
        create_workspace(conn, api_key, %{
          name: "Busy",
          slug: "busy",
          description: "has projects"
        })

      build_conn()
      |> with_api_key(api_key)
      |> post("/api/v1/project", %{
        name: "Backend",
        slug: "backend",
        description: "API server",
        workspace_id: uuid
      })
      |> json_response(201)

      conn = conn |> with_api_key(api_key) |> delete("/api/v1/workspace/#{uuid}")

      assert json_response(conn, 400)["errorMessage"] =~ "still has 1 project"

      workspace = WorkspaceContext.get_workspace_by_uuid(uuid)
      assert workspace != nil
      assert ProjectContext.count_projects_by_workspace(workspace.id) == 1
    end

    test "404 for unknown uuid on delete", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> delete("/api/v1/workspace/00000000-0000-0000-0000-000000000000")

      assert response(conn, 404)
    end
  end
end

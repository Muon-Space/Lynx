defmodule LynxWeb.PolicyControllerTest do
  use LynxWeb.ConnCase

  alias Lynx.Context.PolicyContext
  alias Lynx.Context.RoleContext
  alias Lynx.Context.UserProjectContext

  # `PolicyEngine.Stub` (wired in `config/test.exs`) accepts any source
  # containing a `package` declaration and rejects everything else, so
  # these two constants exercise both sides of the compile check without
  # needing a real OPA on PATH.
  @valid_rego "package lynx.example\n\ndeny[msg] {\n  false\n  msg := \"never\"\n}\n"
  @invalid_rego "deny[msg] { false }\n"

  @unknown_uuid "00000000-0000-0000-0000-000000000000"

  setup %{conn: conn} do
    api_key = install_admin_and_get_api_key(conn)
    {:ok, conn: conn, api_key: api_key}
  end

  defp api(api_key), do: build_conn() |> with_api_key(api_key)

  defp create_workspace(api_key, slug) do
    api(api_key)
    |> post("/api/v1/workspace", %{name: slug, slug: slug, description: "workspace #{slug}"})
    |> json_response(201)
    |> Map.get("id")
  end

  defp create_project(api_key, workspace_uuid, slug) do
    api(api_key)
    |> post("/api/v1/project", %{
      name: slug,
      slug: slug,
      description: "project #{slug}",
      workspace_id: workspace_uuid
    })
    |> json_response(201)
    |> Map.get("id")
  end

  defp create_environment(api_key, project_uuid, slug) do
    api(api_key)
    |> post("/api/v1/project/#{project_uuid}/environment", %{
      name: slug,
      slug: slug,
      username: "user",
      secret: "secret"
    })
    |> json_response(201)
    |> Map.get("id")
  end

  defp create_policy(api_key, attrs) do
    api(api_key)
    |> post("/api/v1/policy", Map.merge(%{name: "policy", rego_source: @valid_rego}, attrs))
    |> json_response(201)
  end

  # A regular user holding the seeded `admin` project role, which is the
  # only default role carrying `policy:manage`.
  defp policy_manager_on(project_uuid) do
    {user, key} = create_regular_user_with_api_key()
    project = Lynx.Context.ProjectContext.get_project_by_uuid(project_uuid)
    role = RoleContext.get_role_by_name("admin")
    {:ok, _} = UserProjectContext.assign_role(user.id, project.id, role.id)
    {user, key}
  end

  # A regular user with a project grant that does NOT include
  # `policy:manage` — `planner` is read/plan only.
  defp planner_on(project_uuid) do
    {user, key} = create_regular_user_with_api_key()
    project = Lynx.Context.ProjectContext.get_project_by_uuid(project_uuid)
    role = RoleContext.get_role_by_name("planner")
    {:ok, _} = UserProjectContext.assign_role(user.id, project.id, role.id)
    {user, key}
  end

  defp scoped_fixtures(api_key) do
    workspace_uuid = create_workspace(api_key, "platform")
    project_uuid = create_project(api_key, workspace_uuid, "backend")
    env_uuid = create_environment(api_key, project_uuid, "staging")
    %{workspace_uuid: workspace_uuid, project_uuid: project_uuid, env_uuid: env_uuid}
  end

  describe "auth" do
    test "GET /api/v1/policy without an API key returns 403", %{conn: conn} do
      assert response(get(conn, "/api/v1/policy"), 403)
    end

    test "POST /api/v1/policy without an API key returns 403", %{conn: conn} do
      assert response(post(conn, "/api/v1/policy", %{name: "x", rego_source: @valid_rego}), 403)
    end
  end

  describe "create" do
    test "creates a global policy", %{api_key: api_key} do
      body =
        create_policy(api_key, %{
          name: "No public buckets",
          description: "org-wide guardrail",
          rego_source: @valid_rego
        })

      assert body["name"] == "No public buckets"
      assert body["description"] == "org-wide guardrail"
      assert body["regoSource"] == @valid_rego
      assert body["enabled"] == true
      assert body["scope"] == "global"
      assert body["workspaceId"] == nil
      assert body["projectId"] == nil
      assert body["environmentId"] == nil
      assert is_binary(body["id"])
    end

    test "creates a workspace-scoped policy and echoes the workspace UUID", %{api_key: api_key} do
      workspace_uuid = create_workspace(api_key, "platform")

      body =
        create_policy(api_key, %{name: "Workspace rule", workspace_uuid: workspace_uuid})

      assert body["scope"] == "workspace"
      assert body["workspaceId"] == workspace_uuid
      assert body["projectId"] == nil
      assert body["environmentId"] == nil
    end

    test "creates a project-scoped policy", %{api_key: api_key} do
      %{project_uuid: project_uuid} = scoped_fixtures(api_key)

      body = create_policy(api_key, %{name: "Project rule", project_uuid: project_uuid})

      assert body["scope"] == "project"
      assert body["projectId"] == project_uuid
    end

    test "creates an environment-scoped policy", %{api_key: api_key} do
      %{env_uuid: env_uuid} = scoped_fixtures(api_key)

      body = create_policy(api_key, %{name: "Env rule", environment_uuid: env_uuid})

      assert body["scope"] == "environment"
      assert body["environmentId"] == env_uuid
    end

    test "honours enabled: false", %{api_key: api_key} do
      body = create_policy(api_key, %{name: "Parked", enabled: false})

      assert body["enabled"] == false
    end

    test "no response field exposes an internal integer key", %{api_key: api_key} do
      %{env_uuid: env_uuid} = scoped_fixtures(api_key)

      body = create_policy(api_key, %{name: "Env rule", environment_uuid: env_uuid})

      refute Enum.any?(Map.values(body), &is_integer/1)
    end

    test "returns 400 when name is missing", %{conn: conn, api_key: api_key} do
      conn = conn |> with_api_key(api_key) |> post("/api/v1/policy", %{rego_source: @valid_rego})

      assert json_response(conn, 400)["errorMessage"] == "Policy name is required"
    end

    test "returns 400 when rego_source is missing", %{conn: conn, api_key: api_key} do
      conn = conn |> with_api_key(api_key) |> post("/api/v1/policy", %{name: "No source"})

      assert json_response(conn, 400)["errorMessage"] == "Policy rego_source is required"
    end

    test "returns 400 when the rego does not compile", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/policy", %{name: "Broken", rego_source: @invalid_rego})

      assert json_response(conn, 400)["errorMessage"] =~ "package"
    end

    test "returns 400 when more than one scope is set", %{conn: conn, api_key: api_key} do
      %{workspace_uuid: workspace_uuid, project_uuid: project_uuid} = scoped_fixtures(api_key)

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/policy", %{
          name: "Two scopes",
          rego_source: @valid_rego,
          workspace_uuid: workspace_uuid,
          project_uuid: project_uuid
        })

      assert json_response(conn, 400)["errorMessage"] ==
               "At most one of workspace_uuid, project_uuid or environment_uuid can be set"
    end

    test "returns 400 when all three scopes are set", %{conn: conn, api_key: api_key} do
      %{workspace_uuid: workspace_uuid, project_uuid: project_uuid, env_uuid: env_uuid} =
        scoped_fixtures(api_key)

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/policy", %{
          name: "Three scopes",
          rego_source: @valid_rego,
          workspace_uuid: workspace_uuid,
          project_uuid: project_uuid,
          environment_uuid: env_uuid
        })

      assert response(conn, 400)
    end

    test "returns 400 for a malformed scope UUID", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/policy", %{
          name: "Bad scope",
          rego_source: @valid_rego,
          project_uuid: "not-a-uuid"
        })

      assert json_response(conn, 400)["errorMessage"] == "project_uuid is invalid"
    end

    test "returns 404 for an unknown scope UUID", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/policy", %{
          name: "Ghost scope",
          rego_source: @valid_rego,
          workspace_uuid: @unknown_uuid
        })

      assert json_response(conn, 404)["errorMessage"] =~ "not found"
    end
  end

  describe "index" do
    test "returns a policy by uuid", %{api_key: api_key} do
      created = create_policy(api_key, %{name: "Readable"})

      body =
        api(api_key) |> get("/api/v1/policy/#{created["id"]}") |> json_response(200)

      assert body["id"] == created["id"]
      assert body["name"] == "Readable"
    end

    test "404 for unknown uuid on get", %{api_key: api_key} do
      assert response(api(api_key) |> get("/api/v1/policy/#{@unknown_uuid}"), 404)
    end
  end

  describe "list" do
    test "returns every policy for a super user", %{api_key: api_key} do
      %{project_uuid: project_uuid} = scoped_fixtures(api_key)
      create_policy(api_key, %{name: "Global one"})
      create_policy(api_key, %{name: "Project one", project_uuid: project_uuid})

      body = api(api_key) |> get("/api/v1/policy") |> json_response(200)

      names = Enum.map(body["policies"], & &1["name"])
      assert "Global one" in names
      assert "Project one" in names
      assert body["_metadata"]["totalCount"] == PolicyContext.count_policies()
    end

    test "reports totalCount and honours limit/offset", %{api_key: api_key} do
      for i <- 1..3, do: create_policy(api_key, %{name: "Policy #{i}"})

      page_one =
        api(api_key) |> get("/api/v1/policy", %{limit: 2, offset: 0}) |> json_response(200)

      assert length(page_one["policies"]) == 2
      assert page_one["_metadata"]["limit"] == 2
      assert page_one["_metadata"]["offset"] == 0
      assert page_one["_metadata"]["totalCount"] == 3

      page_two =
        api(api_key) |> get("/api/v1/policy", %{limit: 2, offset: 2}) |> json_response(200)

      first_ids = Enum.map(page_one["policies"], & &1["id"])
      second_ids = Enum.map(page_two["policies"], & &1["id"])

      assert length(second_ids) == 1
      assert Enum.empty?(first_ids -- (first_ids -- second_ids))
    end

    test "filters by scope=global", %{api_key: api_key} do
      %{project_uuid: project_uuid} = scoped_fixtures(api_key)
      create_policy(api_key, %{name: "Global one"})
      create_policy(api_key, %{name: "Project one", project_uuid: project_uuid})

      body = api(api_key) |> get("/api/v1/policy", %{scope: "global"}) |> json_response(200)

      assert Enum.map(body["policies"], & &1["name"]) == ["Global one"]
      assert body["_metadata"]["totalCount"] == 1
    end

    test "filters by workspace_uuid", %{api_key: api_key} do
      %{workspace_uuid: workspace_uuid} = scoped_fixtures(api_key)
      create_policy(api_key, %{name: "Global one"})
      create_policy(api_key, %{name: "Workspace one", workspace_uuid: workspace_uuid})

      body =
        api(api_key)
        |> get("/api/v1/policy", %{workspace_uuid: workspace_uuid})
        |> json_response(200)

      assert Enum.map(body["policies"], & &1["name"]) == ["Workspace one"]
    end

    test "filters by project_uuid", %{api_key: api_key} do
      %{project_uuid: project_uuid} = scoped_fixtures(api_key)
      create_policy(api_key, %{name: "Global one"})
      create_policy(api_key, %{name: "Project one", project_uuid: project_uuid})

      body =
        api(api_key)
        |> get("/api/v1/policy", %{project_uuid: project_uuid})
        |> json_response(200)

      assert Enum.map(body["policies"], & &1["name"]) == ["Project one"]
    end

    test "filters by environment_uuid", %{api_key: api_key} do
      %{env_uuid: env_uuid} = scoped_fixtures(api_key)
      create_policy(api_key, %{name: "Global one"})
      create_policy(api_key, %{name: "Env one", environment_uuid: env_uuid})

      body =
        api(api_key) |> get("/api/v1/policy", %{environment_uuid: env_uuid}) |> json_response(200)

      assert Enum.map(body["policies"], & &1["name"]) == ["Env one"]
    end

    test "returns 400 when more than one scope filter is given", %{api_key: api_key} do
      %{workspace_uuid: workspace_uuid, project_uuid: project_uuid} = scoped_fixtures(api_key)

      conn =
        api(api_key)
        |> get("/api/v1/policy", %{
          workspace_uuid: workspace_uuid,
          project_uuid: project_uuid
        })

      assert json_response(conn, 400)["errorMessage"] ==
               "At most one of workspace_uuid, project_uuid or environment_uuid can be set"
    end

    test "returns 400 for an unsupported scope value", %{api_key: api_key} do
      conn = api(api_key) |> get("/api/v1/policy", %{scope: "project"})

      assert json_response(conn, 400)["errorMessage"] =~ "scope only accepts"
    end
  end

  describe "permissions" do
    test "regular user with no grants sees an empty list", %{api_key: api_key} do
      create_policy(api_key, %{name: "Global one"})
      {_user, regular_key} = create_regular_user_with_api_key()

      body = api(regular_key) |> get("/api/v1/policy") |> json_response(200)

      assert body["policies"] == []
      assert body["_metadata"]["totalCount"] == 0
    end

    test "policy manager sees only their project's and env's policies", %{api_key: api_key} do
      %{project_uuid: project_uuid, env_uuid: env_uuid, workspace_uuid: workspace_uuid} =
        scoped_fixtures(api_key)

      other_project = create_project(api_key, workspace_uuid, "frontend")

      create_policy(api_key, %{name: "Global one"})
      create_policy(api_key, %{name: "Workspace one", workspace_uuid: workspace_uuid})
      create_policy(api_key, %{name: "Project one", project_uuid: project_uuid})
      create_policy(api_key, %{name: "Env one", environment_uuid: env_uuid})
      create_policy(api_key, %{name: "Other project", project_uuid: other_project})

      {_user, key} = policy_manager_on(project_uuid)

      body = api(key) |> get("/api/v1/policy") |> json_response(200)

      assert Enum.sort(Enum.map(body["policies"], & &1["name"])) == ["Env one", "Project one"]
      assert body["_metadata"]["totalCount"] == 2
    end

    test "policy manager can paginate", %{api_key: api_key} do
      # The non-super branch slices in memory rather than in the database,
      # and query params arrive as strings, so this combination is the one
      # that previously raised on the workspace endpoint. The super-user
      # branch goes through Ecto, which tolerates the strings.
      %{project_uuid: project_uuid} = scoped_fixtures(api_key)

      for i <- 1..3,
          do: create_policy(api_key, %{name: "Policy #{i}", project_uuid: project_uuid})

      {_user, key} = policy_manager_on(project_uuid)

      body =
        api(key) |> get("/api/v1/policy", %{limit: 2, offset: 1}) |> json_response(200)

      assert length(body["policies"]) == 2
      assert body["_metadata"]["limit"] == 2
      assert body["_metadata"]["offset"] == 1
      assert body["_metadata"]["totalCount"] == 3
    end

    test "policy manager can CRUD a policy on their project", %{api_key: api_key} do
      %{project_uuid: project_uuid} = scoped_fixtures(api_key)
      {_user, key} = policy_manager_on(project_uuid)

      created =
        api(key)
        |> post("/api/v1/policy", %{
          name: "Delegated",
          rego_source: @valid_rego,
          project_uuid: project_uuid
        })
        |> json_response(201)

      assert created["projectId"] == project_uuid

      assert api(key) |> get("/api/v1/policy/#{created["id"]}") |> json_response(200)

      updated =
        api(key)
        |> put("/api/v1/policy/#{created["id"]}", %{
          name: "Delegated v2",
          rego_source: @valid_rego
        })
        |> json_response(200)

      assert updated["name"] == "Delegated v2"

      assert response(api(key) |> delete("/api/v1/policy/#{created["id"]}"), 204)
    end

    test "policy manager cannot create a global policy", %{api_key: api_key} do
      %{project_uuid: project_uuid} = scoped_fixtures(api_key)
      {_user, key} = policy_manager_on(project_uuid)

      conn = api(key) |> post("/api/v1/policy", %{name: "Sneaky", rego_source: @valid_rego})

      assert response(conn, 403)
    end

    test "policy manager cannot create a workspace policy", %{api_key: api_key} do
      %{project_uuid: project_uuid, workspace_uuid: workspace_uuid} = scoped_fixtures(api_key)
      {_user, key} = policy_manager_on(project_uuid)

      conn =
        api(key)
        |> post("/api/v1/policy", %{
          name: "Sneaky",
          rego_source: @valid_rego,
          workspace_uuid: workspace_uuid
        })

      assert response(conn, 403)
    end

    test "policy manager cannot read or delete a global policy", %{api_key: api_key} do
      %{project_uuid: project_uuid} = scoped_fixtures(api_key)
      global = create_policy(api_key, %{name: "Global one"})
      {_user, key} = policy_manager_on(project_uuid)

      assert response(api(key) |> get("/api/v1/policy/#{global["id"]}"), 403)
      assert response(api(key) |> delete("/api/v1/policy/#{global["id"]}"), 403)
    end

    test "policy manager cannot touch another project's policy", %{api_key: api_key} do
      %{project_uuid: project_uuid, workspace_uuid: workspace_uuid} = scoped_fixtures(api_key)
      other_project = create_project(api_key, workspace_uuid, "frontend")
      other = create_policy(api_key, %{name: "Other", project_uuid: other_project})

      {_user, key} = policy_manager_on(project_uuid)

      assert response(api(key) |> get("/api/v1/policy/#{other["id"]}"), 403)

      assert response(
               api(key)
               |> put("/api/v1/policy/#{other["id"]}", %{
                 name: "Hijacked",
                 rego_source: @valid_rego
               }),
               403
             )

      assert response(api(key) |> delete("/api/v1/policy/#{other["id"]}"), 403)
    end

    test "a project grant without policy:manage is not enough", %{api_key: api_key} do
      %{project_uuid: project_uuid} = scoped_fixtures(api_key)
      policy = create_policy(api_key, %{name: "Project one", project_uuid: project_uuid})

      {_user, key} = planner_on(project_uuid)

      assert response(api(key) |> get("/api/v1/policy/#{policy["id"]}"), 403)

      assert response(
               api(key)
               |> post("/api/v1/policy", %{
                 name: "Nope",
                 rego_source: @valid_rego,
                 project_uuid: project_uuid
               }),
               403
             )

      body = api(key) |> get("/api/v1/policy") |> json_response(200)
      assert body["policies"] == []
    end

    test "regular user cannot filter the list by a scope they don't manage", %{api_key: api_key} do
      %{workspace_uuid: workspace_uuid, project_uuid: project_uuid} = scoped_fixtures(api_key)
      {_user, key} = create_regular_user_with_api_key()

      assert response(api(key) |> get("/api/v1/policy", %{scope: "global"}), 403)

      assert response(
               api(key) |> get("/api/v1/policy", %{workspace_uuid: workspace_uuid}),
               403
             )

      assert response(api(key) |> get("/api/v1/policy", %{project_uuid: project_uuid}), 403)
    end
  end

  describe "update" do
    test "updates a policy", %{api_key: api_key} do
      created = create_policy(api_key, %{name: "Original", description: "before"})
      new_rego = "package lynx.updated\n"

      body =
        api(api_key)
        |> put("/api/v1/policy/#{created["id"]}", %{
          name: "Renamed",
          description: "after",
          rego_source: new_rego,
          enabled: false
        })
        |> json_response(200)

      assert body["id"] == created["id"]
      assert body["name"] == "Renamed"
      assert body["description"] == "after"
      assert body["regoSource"] == new_rego
      assert body["enabled"] == false
      assert body["scope"] == "global"
    end

    test "repeating the current scope is allowed", %{api_key: api_key} do
      %{project_uuid: project_uuid} = scoped_fixtures(api_key)
      created = create_policy(api_key, %{name: "Scoped", project_uuid: project_uuid})

      body =
        api(api_key)
        |> put("/api/v1/policy/#{created["id"]}", %{
          name: "Scoped v2",
          rego_source: @valid_rego,
          project_uuid: project_uuid
        })
        |> json_response(200)

      assert body["name"] == "Scoped v2"
      assert body["projectId"] == project_uuid
    end

    test "returns 400 when the update would move the policy to another scope", %{
      api_key: api_key
    } do
      %{project_uuid: project_uuid, workspace_uuid: workspace_uuid} = scoped_fixtures(api_key)
      created = create_policy(api_key, %{name: "Scoped", project_uuid: project_uuid})

      conn =
        api(api_key)
        |> put("/api/v1/policy/#{created["id"]}", %{
          name: "Scoped",
          rego_source: @valid_rego,
          workspace_uuid: workspace_uuid
        })

      assert json_response(conn, 400)["errorMessage"] =~ "scope can't be changed"
    end

    test "returns 400 when the new rego does not compile", %{api_key: api_key} do
      created = create_policy(api_key, %{name: "Original"})

      conn =
        api(api_key)
        |> put("/api/v1/policy/#{created["id"]}", %{
          name: "Original",
          rego_source: @invalid_rego
        })

      assert json_response(conn, 400)["errorMessage"] =~ "package"
    end

    test "returns 400 when name is missing", %{api_key: api_key} do
      created = create_policy(api_key, %{name: "Original"})

      conn =
        api(api_key)
        |> put("/api/v1/policy/#{created["id"]}", %{rego_source: @valid_rego})

      assert response(conn, 400)
    end

    test "404 for unknown uuid on update", %{api_key: api_key} do
      conn =
        api(api_key)
        |> put("/api/v1/policy/#{@unknown_uuid}", %{
          name: "Ghost",
          rego_source: @valid_rego
        })

      assert response(conn, 404)
    end
  end

  describe "delete" do
    test "deletes a policy", %{api_key: api_key} do
      created = create_policy(api_key, %{name: "Doomed"})

      assert response(api(api_key) |> delete("/api/v1/policy/#{created["id"]}"), 204)
      assert PolicyContext.get_policy_by_uuid(created["id"]) == nil
    end

    test "404 for unknown uuid on delete", %{api_key: api_key} do
      assert response(api(api_key) |> delete("/api/v1/policy/#{@unknown_uuid}"), 404)
    end
  end
end

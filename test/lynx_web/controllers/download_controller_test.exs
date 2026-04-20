defmodule LynxWeb.DownloadControllerTest do
  use LynxWeb.ConnCase

  alias Lynx.Context.{
    EnvironmentContext,
    ProjectContext,
    StateContext,
    UserContext,
    WorkspaceContext
  }

  alias Lynx.Service.AuthService

  setup %{conn: conn} do
    install_admin_and_get_api_key(conn)
    user = UserContext.get_user_by_email("john@example.com")
    {:ok, conn: conn, user: user}
  end

  defp log_in_session(conn, user) do
    {:success, session} = AuthService.authenticate(user.id)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:uid, user.id)
    |> Plug.Conn.put_session(:token, session.value)
  end

  defp create_test_setup do
    {:ok, ws} =
      WorkspaceContext.create_workspace(
        WorkspaceContext.new_workspace(%{
          name: "WS#{System.unique_integer([:positive])}",
          slug: "ws-#{System.unique_integer([:positive])}",
          description: "test"
        })
      )

    {:ok, project} =
      ProjectContext.create_project(
        ProjectContext.new_project(%{
          name: "P",
          slug: "p-#{System.unique_integer([:positive])}",
          description: "test",
          workspace_id: ws.id
        })
      )

    {:ok, env} =
      EnvironmentContext.create_env(
        EnvironmentContext.new_env(%{
          name: "Env",
          slug: "env-#{System.unique_integer([:positive])}",
          username: "u",
          secret: "s",
          project_id: project.id
        })
      )

    {ws, project, env}
  end

  describe "GET /admin/state/download/:uuid (anonymous)" do
    test "redirects to /login when not logged in", %{conn: conn} do
      {_, _, env} = create_test_setup()

      {:ok, state} =
        StateContext.create_state(
          StateContext.new_state(%{
            name: "s",
            value: ~s({"v":1}),
            sub_path: "",
            environment_id: env.id
          })
        )

      conn = get(conn, "/admin/state/download/#{state.uuid}")
      assert redirected_to(conn) == "/login"
    end
  end

  describe "GET /admin/state/download/:uuid (authenticated)" do
    test "downloads state with correct headers", %{conn: conn, user: user} do
      {_, _, env} = create_test_setup()

      {:ok, state} =
        StateContext.create_state(
          StateContext.new_state(%{
            name: "s",
            value: ~s({"v":42}),
            sub_path: "",
            environment_id: env.id
          })
        )

      conn = conn |> log_in_session(user) |> get("/admin/state/download/#{state.uuid}")

      assert conn.status == 200
      assert conn.resp_body == ~s({"v":42})

      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/octet-stream"

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "state.#{state.uuid}.json"
    end

    test "redirects to /404 when state uuid not found", %{conn: conn, user: user} do
      conn =
        conn
        |> log_in_session(user)
        |> get("/admin/state/download/00000000-0000-0000-0000-000000000000")

      assert redirected_to(conn) == "/404"
    end
  end

  describe "GET /admin/environment/download/:uuid (anonymous)" do
    test "redirects to /login when not logged in", %{conn: conn} do
      {_, _, env} = create_test_setup()
      conn = get(conn, "/admin/environment/download/#{env.uuid}")
      assert redirected_to(conn) == "/login"
    end
  end

  describe "GET /admin/environment/download/:uuid (authenticated)" do
    test "downloads latest root state with default filename", %{conn: conn, user: user} do
      {_, _, env} = create_test_setup()

      {:ok, _} =
        StateContext.create_state(
          StateContext.new_state(%{
            name: "s",
            value: ~s({"v":"old"}),
            sub_path: "",
            environment_id: env.id
          })
        )

      {:ok, latest} =
        StateContext.create_state(
          StateContext.new_state(%{
            name: "s",
            value: ~s({"v":"new"}),
            sub_path: "",
            environment_id: env.id
          })
        )

      conn = conn |> log_in_session(user) |> get("/admin/environment/download/#{env.uuid}")

      assert conn.status == 200
      assert conn.resp_body == ~s({"v":"new"})

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "state.#{latest.uuid}.json"
    end

    test "downloads sub_path state with sanitized filename", %{conn: conn, user: user} do
      {_, _, env} = create_test_setup()

      {:ok, state} =
        StateContext.create_state(
          StateContext.new_state(%{
            name: "s",
            value: ~s({"unit":"dns"}),
            sub_path: "infra/dns",
            environment_id: env.id
          })
        )

      conn =
        conn
        |> log_in_session(user)
        |> get("/admin/environment/download/#{env.uuid}?sub_path=infra/dns")

      assert conn.status == 200
      assert conn.resp_body == ~s({"unit":"dns"})

      [disposition] = get_resp_header(conn, "content-disposition")
      # `/` is replaced with `-` in the filename
      assert disposition =~ "state.infra-dns.#{state.uuid}.json"
    end

    test "redirects to /404 when env not found", %{conn: conn, user: user} do
      conn =
        conn
        |> log_in_session(user)
        |> get("/admin/environment/download/00000000-0000-0000-0000-000000000000")

      assert redirected_to(conn) == "/404"
    end

    test "redirects to /404 when env exists but has no state", %{conn: conn, user: user} do
      {_, _, env} = create_test_setup()
      conn = conn |> log_in_session(user) |> get("/admin/environment/download/#{env.uuid}")
      assert redirected_to(conn) == "/404"
    end
  end
end

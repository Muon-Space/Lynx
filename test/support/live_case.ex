defmodule LynxWeb.LiveCase do
  @moduledoc """
  Test case for Phoenix LiveView pages.

  Provides:
  - Phoenix.LiveViewTest imports for `live/2`, `render_*` helpers
  - DB sandbox setup (via Lynx.DataCase)
  - User factories: `create_user/1`, `create_super/1`
  - Auth helper: `log_in_user/2` puts session keys the LiveAuth hook reads
  """

  use ExUnit.CaseTemplate

  alias Lynx.Context.{
    ConfigContext,
    EnvironmentContext,
    LockContext,
    ProjectContext,
    StateContext,
    UserContext,
    WorkspaceContext
  }

  alias Lynx.Service.AuthService

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import LynxWeb.LiveCase

      @endpoint LynxWeb.Endpoint
    end
  end

  setup tags do
    Lynx.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})}
  end

  @doc """
  Inserts an active user. Defaults to role: "user".
  """
  def create_user(attrs \\ %{}) do
    salt = AuthService.get_random_salt()
    password = Map.get(attrs, :password, "password123")

    defaults = %{
      email: "user-#{System.unique_integer([:positive])}@example.com",
      name: "Test User",
      password_hash: AuthService.hash_password(password, salt),
      verified: true,
      last_seen: DateTime.utc_now() |> DateTime.truncate(:second),
      role: "user",
      api_key: AuthService.get_random_salt(20),
      uuid: Ecto.UUID.generate(),
      is_active: true
    }

    {:ok, user} =
      defaults
      |> Map.merge(attrs)
      |> UserContext.new_user()
      |> UserContext.create_user()

    user
  end

  @doc """
  Inserts an active super user.
  """
  def create_super(attrs \\ %{}) do
    create_user(Map.merge(%{role: "super"}, attrs))
  end

  @doc """
  Creates a session for the user and writes the session keys
  that `LynxWeb.LiveAuth` reads (`uid`, `token`).
  """
  def log_in_user(conn, user) do
    {:success, session} = AuthService.authenticate(user.id)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:uid, user.id)
    |> Plug.Conn.put_session(:token, session.value)
  end

  @doc """
  Inserts a workspace.
  """
  def create_workspace(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      name: "Workspace #{n}",
      slug: "ws-#{n}",
      description: "test workspace"
    }

    {:ok, ws} =
      defaults
      |> Map.merge(attrs)
      |> WorkspaceContext.new_workspace()
      |> WorkspaceContext.create_workspace()

    ws
  end

  @doc """
  Inserts a project. Pass `:workspace_id` to link, otherwise a new workspace is created.
  """
  def create_project(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    workspace_id = Map.get(attrs, :workspace_id) || create_workspace().id

    defaults = %{
      name: "Project #{n}",
      slug: "proj-#{n}",
      description: "test project",
      workspace_id: workspace_id
    }

    {:ok, project} =
      defaults
      |> Map.merge(attrs)
      |> ProjectContext.new_project()
      |> ProjectContext.create_project()

    project
  end

  @doc """
  Inserts an environment under the given project.
  """
  def create_env(project, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      name: "Env #{n}",
      slug: "env-#{n}",
      username: "u-#{n}",
      secret: "s-#{n}",
      project_id: project.id
    }

    {:ok, env} =
      defaults
      |> Map.merge(attrs)
      |> EnvironmentContext.new_env()
      |> EnvironmentContext.create_env()

    env
  end

  @doc """
  Inserts a state row for an environment. Pass `:value` to set the state JSON.
  """
  def create_state(env, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      name: "state-#{n}",
      value: ~s({"version":#{n}}),
      sub_path: "",
      environment_id: env.id
    }

    {:ok, state} =
      defaults
      |> Map.merge(attrs)
      |> StateContext.new_state()
      |> StateContext.create_state()

    state
  end

  @doc """
  Marks the app as installed by seeding the same configs the real install
  flow writes: `is_installed`, `app_key`, `app_name`, `app_url`, `app_email`.

  Several LVs read these (Home, Login, SettingsLive's `update_configs/1`),
  and user-creation paths need `app_key` for bcrypt salt derivation.
  """
  def mark_installed do
    rows = [
      %{name: "is_installed", value: "yes"},
      %{name: "app_key", value: AuthService.get_random_salt()},
      %{name: "app_name", value: "Lynx Test"},
      %{name: "app_url", value: "http://localhost:4000"},
      %{name: "app_email", value: "test@lynx.test"}
    ]

    for row <- rows do
      {:ok, _} = ConfigContext.create_config(ConfigContext.new_config(row))
    end

    :ok
  end

  @doc """
  Sets a config row by name. Useful for toggling SSO/password auth in tests.
  """
  def set_config(name, value) do
    {:ok, _} =
      ConfigContext.create_config(ConfigContext.new_config(%{name: name, value: value}))

    :ok
  end

  @doc """
  Inserts an active lock on the environment + sub_path.
  """
  def create_lock(env, attrs \\ %{}) do
    defaults = %{
      environment_id: env.id,
      operation: "manual",
      info: "test lock",
      who: "tester",
      version: "",
      path: "",
      sub_path: "",
      uuid: Ecto.UUID.generate(),
      is_active: true
    }

    {:ok, lock} =
      defaults
      |> Map.merge(attrs)
      |> LockContext.new_lock()
      |> LockContext.create_lock()

    lock
  end
end

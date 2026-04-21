defmodule LynxWeb.Plug.RequirePerm do
  @moduledoc """
  Per-permission gate for `/api/v1/*` write endpoints.

  Wraps `Lynx.Context.RoleContext.can?/3`: resolves the project from the
  request's URL params, then checks whether the authenticated user has the
  named permission on that project. Returns `403 Forbidden` if not.

  ## Usage

      plug LynxWeb.Plug.RequirePerm,
        permission: "project:manage",
        from: :project_uuid

  ### `:from` strategies

  How to find the project given the conn — pick the one that matches the
  URL's path-binding shape:

    * `:project_uuid` — `params["uuid"]` is a project UUID
                       (e.g. `PUT /api/v1/project/:uuid`)
    * `:project_p_uuid` — `params["p_uuid"]` is a project UUID
                          (e.g. `PUT /api/v1/project/:p_uuid/environment/:e_uuid`)
    * `:env_uuid` — `params["e_uuid"]` is an environment UUID; resolve to its project
                    (e.g. `POST /api/v1/environment/:e_uuid/lock`)
    * `:env_p_uuid` — same but env's UUID lives in `params["p_uuid"]`
                      (legacy/oddly-named routes)
    * `:snapshot_uuid` — `params["uuid"]` is a snapshot UUID; resolve via its
                         `record_type` + `record_uuid` to the owning project
    * `:oidc_rule_env` — `params["environment_id"]` is an env UUID
                         (used by `POST /api/v1/oidc_rule`)
    * `:oidc_rule_uuid` — `params["uuid"]` is an OIDC rule UUID; resolve via
                          rule -> environment -> project

  Super users always pass — `RoleContext.effective_permissions/2` returns the
  full permission set for them.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Lynx.Context.{
    EnvironmentContext,
    OIDCAccessRuleContext,
    ProjectContext,
    RoleContext,
    SnapshotContext,
    UserContext
  }

  @type from ::
          :project_uuid
          | :project_p_uuid
          | :env_uuid
          | :env_p_uuid
          | :snapshot_uuid
          | :oidc_rule_env
          | :oidc_rule_uuid

  def init(opts) do
    permission = Keyword.fetch!(opts, :permission)
    from = Keyword.fetch!(opts, :from)
    %{permission: permission, from: from}
  end

  def call(conn, %{permission: permission, from: from}) do
    with {:ok, user} <- fetch_user(conn),
         {:ok, project} <- fetch_project(conn, from) do
      if RoleContext.can?(user, project, permission) do
        conn
      else
        forbidden(conn, "Insufficient role for #{permission}")
      end
    else
      {:error, status, msg} -> error_response(conn, status, msg)
    end
  end

  # -- User --

  defp fetch_user(conn) do
    case conn.assigns[:user_id] do
      nil ->
        {:error, :forbidden, "Forbidden Access"}

      user_id ->
        case UserContext.get_user_by_id(user_id) do
          nil -> {:error, :forbidden, "Forbidden Access"}
          user -> {:ok, user}
        end
    end
  end

  # -- Project resolution --

  defp fetch_project(conn, :project_uuid),
    do: lookup_project(conn.params["uuid"])

  defp fetch_project(conn, :project_p_uuid),
    do: lookup_project(conn.params["p_uuid"])

  defp fetch_project(conn, :env_uuid),
    do: lookup_project_via_env(conn.params["e_uuid"])

  defp fetch_project(conn, :env_p_uuid),
    do: lookup_project_via_env(conn.params["p_uuid"])

  defp fetch_project(conn, :snapshot_uuid) do
    case SnapshotContext.get_snapshot_by_uuid(conn.params["uuid"]) do
      nil ->
        {:error, :not_found, "Snapshot not found"}

      snapshot ->
        case SnapshotContext.get_project_for_snapshot(snapshot) do
          nil -> {:error, :not_found, "Project not found"}
          project -> {:ok, project}
        end
    end
  end

  defp fetch_project(conn, :oidc_rule_env),
    do: lookup_project_via_env(conn.params["environment_id"])

  defp fetch_project(conn, :oidc_rule_uuid) do
    case OIDCAccessRuleContext.get_rule_by_uuid(conn.params["uuid"]) do
      nil ->
        {:error, :not_found, "Rule not found"}

      rule ->
        case ProjectContext.get_project_by_id(env_project_id(rule.environment_id)) do
          nil -> {:error, :not_found, "Project not found"}
          project -> {:ok, project}
        end
    end
  end

  defp lookup_project(nil), do: {:error, :not_found, "Project not found"}

  defp lookup_project(uuid) do
    case ProjectContext.get_project_by_uuid(uuid) do
      nil -> {:error, :not_found, "Project not found"}
      project -> {:ok, project}
    end
  end

  defp lookup_project_via_env(nil), do: {:error, :not_found, "Environment not found"}

  defp lookup_project_via_env(env_uuid) do
    case EnvironmentContext.get_env_by_uuid(env_uuid) do
      nil ->
        {:error, :not_found, "Environment not found"}

      env ->
        case ProjectContext.get_project_by_id(env.project_id) do
          nil -> {:error, :not_found, "Project not found"}
          project -> {:ok, project}
        end
    end
  end

  defp env_project_id(env_id) do
    case EnvironmentContext.get_env_by_id(env_id) do
      nil -> nil
      env -> env.project_id
    end
  end

  # -- Response --

  defp forbidden(conn, msg), do: error_response(conn, :forbidden, msg)

  defp error_response(conn, status, msg) do
    # `json/2` works for every REST controller; some have a JSON view module
    # (and use `render(:error, ...)`), the OIDC controller doesn't (uses
    # `json(...)` directly). The wire shape `{errorMessage: ...}` matches
    # what those controllers already emit.
    conn
    |> put_status(status)
    |> json(%{errorMessage: msg})
    |> halt()
  end
end

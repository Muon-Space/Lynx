# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.EnvironmentController do
  @moduledoc """
  Environment Controller
  """

  use LynxWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Lynx.Context.EnvironmentContext
  alias Lynx.Context.AuditContext
  alias Lynx.Service.ValidatorService
  alias Lynx.Service.Permission
  alias LynxWeb.Schemas

  @name_min_length 2
  @name_max_length 60
  @username_min_length 2
  @username_max_length 60
  @secret_min_length 2
  @secret_max_length 60
  @slug_min_length 2
  @slug_max_length 60

  @default_list_limit 10
  @default_list_offset 0

  plug :regular_user when action in [:list, :index, :create, :update, :delete]
  plug :access_check when action in [:list, :index, :create, :update, :delete]

  plug LynxWeb.Plug.RequirePerm,
       [permission: "env:manage", from: :project_p_uuid]
       when action in [:create, :update, :delete]

  plug LynxWeb.Plug.RequirePerm,
       [permission: "state:lock", from: :env_uuid]
       when action == :force_lock

  plug LynxWeb.Plug.RequirePerm,
       [permission: "state:force_unlock", from: :env_uuid]
       when action == :force_unlock

  tags(["Environments"])
  security([%{"api_key" => []}])

  operation(:list,
    summary: "List environments in a project",
    parameters: [
      p_uuid: [in: :path, required: true, type: :string, description: "Project UUID"],
      limit: [in: :query, type: :integer, description: "Default 10"],
      offset: [in: :query, type: :integer, description: "Default 0"]
    ],
    responses: [
      ok: {"Environments", "application/json", Schemas.EnvironmentList},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  operation(:create,
    summary: "Create an environment",
    description: "Requires `env:manage` (admin) on the project.",
    parameters: [
      p_uuid: [in: :path, required: true, type: :string, description: "Project UUID"]
    ],
    request_body: {"Environment", "application/json", Schemas.EnvironmentCreate},
    responses: [
      created: {"Created", "application/json", Schemas.Environment},
      bad_request: {"Validation error", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:index,
    summary: "Get an environment by UUID",
    parameters: [
      p_uuid: [in: :path, required: true, type: :string, description: "Project UUID"],
      e_uuid: [in: :path, required: true, type: :string, description: "Environment UUID"]
    ],
    responses: [
      ok: {"Environment", "application/json", Schemas.Environment},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  operation(:update,
    summary: "Update an environment",
    description: "Requires `env:manage` (admin) on the project.",
    parameters: [
      p_uuid: [in: :path, required: true, type: :string],
      e_uuid: [in: :path, required: true, type: :string]
    ],
    request_body: {"Environment", "application/json", Schemas.EnvironmentCreate},
    responses: [
      ok: {"Environment", "application/json", Schemas.Environment},
      bad_request: {"Validation error", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:delete,
    summary: "Delete an environment",
    description: "Requires `env:manage` (admin) on the project.",
    parameters: [
      p_uuid: [in: :path, required: true, type: :string],
      e_uuid: [in: :path, required: true, type: :string]
    ],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:force_lock,
    summary: "Force-lock an environment",
    description: "Requires `state:lock` on the env's project.",
    parameters: [
      e_uuid: [in: :path, required: true, type: :string, description: "Environment UUID"]
    ],
    responses: [
      ok: {"Locked", "application/json", Schemas.Success},
      forbidden: {"Forbidden", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      bad_request: {"Bad request", "application/json", Schemas.Error}
    ]
  )

  operation(:force_unlock,
    summary: "Force-unlock an environment (admin only)",
    description: """
    Clears the active lock — the destructive variant. Requires
    `state:force_unlock` (admin only). Note that the routine post-apply
    unlock that Terraform calls automatically uses `/tf/.../unlock` and
    only requires `state:unlock`.
    """,
    parameters: [
      e_uuid: [in: :path, required: true, type: :string, description: "Environment UUID"]
    ],
    responses: [
      ok: {"Unlocked", "application/json", Schemas.Success},
      forbidden: {"Forbidden", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      bad_request: {"Bad request", "application/json", Schemas.Error}
    ]
  )

  defp regular_user(conn, _opts) do
    Logger.info("Validate user permissions")

    if not conn.assigns[:is_logged] do
      Logger.info("User doesn't have the right access permissions")

      conn
      |> put_status(:forbidden)
      |> render(:error, %{message: "Forbidden Access"})
      |> halt
    else
      Logger.info("User has the right access permissions")

      conn
    end
  end

  defp access_check(conn, _opts) do
    Logger.info("Validate if user can access project")

    if not Permission.can_access_project_uuid(
         :project,
         conn.assigns[:user_role],
         conn.params["p_uuid"],
         conn.assigns[:user_id]
       ) do
      Logger.info("User doesn't own the project")

      conn
      |> put_status(:forbidden)
      |> render(:error, %{message: "Forbidden Access"})
      |> halt
    else
      Logger.info("User can access the project")

      conn
    end
  end

  @doc """
  List Action Endpoint
  """
  def list(conn, params) do
    limit = params["limit"] || @default_list_limit
    offset = params["offset"] || @default_list_offset

    result = EnvironmentContext.get_project_environments(params["p_uuid"], offset, limit)
    count = EnvironmentContext.count_project_environments(params["p_uuid"])

    case result do
      {:not_found, msg} ->
        conn
        |> put_status(:not_found)
        |> render(:error, %{message: msg})

      {:ok, environments} ->
        render(conn, "list.json", %{
          environments: environments,
          metadata: %{
            limit: limit,
            offset: offset,
            totalCount: count
          }
        })
    end
  end

  @doc """
  Create Action Endpoint
  """
  def create(conn, params) do
    case validate_create_request(params, params["p_uuid"]) do
      {:ok, ""} ->
        result =
          EnvironmentContext.create_environment(%{
            name: params["name"],
            slug: params["slug"],
            username: params["username"],
            secret: params["secret"],
            project_id: params["p_uuid"]
          })

        case result do
          {:ok, environment} ->
            conn
            |> put_status(:created)
            |> render(:index, %{environment: environment})

          {:error, msg} ->
            conn
            |> put_status(:bad_request)
            |> render(:error, %{message: msg})
        end

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> render(:error, %{message: reason})
    end
  end

  @doc """
  Index Action Endpoint
  """
  def index(conn, %{"p_uuid" => p_uuid, "e_uuid" => e_uuid}) do
    case EnvironmentContext.get_environment_by_uuid(p_uuid, e_uuid) do
      {:not_found, msg} ->
        conn
        |> put_status(:not_found)
        |> render(:error, %{message: msg})

      {:ok, environment} ->
        conn
        |> put_status(:ok)
        |> render(:index, %{environment: environment})
    end
  end

  @doc """
  Update Action Endpoint
  """
  def update(conn, params) do
    case validate_update_request(params, params["p_uuid"], params["e_uuid"]) do
      {:ok, ""} ->
        result =
          EnvironmentContext.update_environment(%{
            uuid: params["e_uuid"],
            name: params["name"],
            slug: params["slug"],
            username: params["username"],
            secret: params["secret"],
            project_id: params["p_uuid"]
          })

        case result do
          {:ok, environment} ->
            conn
            |> put_status(:ok)
            |> render(:index, %{environment: environment})

          {:error, msg} ->
            conn
            |> put_status(:bad_request)
            |> render(:error, %{message: msg})
        end

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> render(:error, %{message: reason})
    end
  end

  @doc """
  Delete Action Endpoint
  """
  def delete(conn, %{"p_uuid" => p_uuid, "e_uuid" => e_uuid}) do
    case EnvironmentContext.delete_environment_by_uuid(p_uuid, e_uuid) do
      {:not_found, msg} ->
        conn
        |> put_status(:not_found)
        |> render(:error, %{message: msg})

      {:ok, _} ->
        conn
        |> send_resp(:no_content, "")
    end
  end

  @doc """
  Force Lock Environment Endpoint
  """
  def force_lock(conn, %{"e_uuid" => e_uuid}) do
    alias Lynx.Context.LockContext
    alias Lynx.Context.EnvironmentContext

    case EnvironmentContext.get_env_id_with_uuid(e_uuid) do
      nil ->
        conn
        |> put_status(:not_found)
        |> render(:error, %{message: "Environment not found"})

      env_id ->
        case LockContext.force_lock(env_id, conn.assigns[:user_name] || "admin") do
          {:success, msg} ->
            AuditContext.log(conn, "locked", "environment", e_uuid)

            conn |> put_status(:ok) |> json(%{successMessage: msg})

          {:already_locked, msg} ->
            conn |> put_status(:ok) |> json(%{successMessage: msg})

          {:error, msg} ->
            conn |> put_status(:bad_request) |> render(:error, %{message: msg})
        end
    end
  end

  @doc """
  Force Unlock Environment Endpoint
  """
  def force_unlock(conn, %{"e_uuid" => e_uuid}) do
    alias Lynx.Context.LockContext
    alias Lynx.Context.EnvironmentContext

    case EnvironmentContext.get_env_id_with_uuid(e_uuid) do
      nil ->
        conn
        |> put_status(:not_found)
        |> render(:error, %{message: "Environment not found"})

      env_id ->
        case LockContext.force_unlock(env_id) do
          {:success, msg} ->
            AuditContext.log(conn, "unlocked", "environment", e_uuid)

            conn |> put_status(:ok) |> json(%{successMessage: msg})

          {:error, msg} ->
            conn |> put_status(:bad_request) |> render(:error, %{message: msg})
        end
    end
  end

  defp validate_create_request(params, project_uuid) do
    errs = %{
      name_required: "Environment name is required",
      name_invalid: "Environment name is invalid",
      username_required: "Environment username is required",
      username_invalid: "Environment username is invalid",
      secret_required: "Environment secret is required",
      secret_invalid: "Environment secret is invalid",
      slug_required: "Environment slug is required",
      slug_invalid: "Environment slug is invalid",
      slug_used: "Environment slug is already used",
      project_uuid_invalid: "Project ID is invalid"
    }

    with {:ok, _} <- ValidatorService.is_string?(params["name"], errs.name_required),
         {:ok, _} <- ValidatorService.is_string?(params["username"], errs.username_required),
         {:ok, _} <- ValidatorService.is_string?(params["secret"], errs.secret_required),
         {:ok, _} <- ValidatorService.is_string?(params["slug"], errs.slug_required),
         {:ok, _} <-
           ValidatorService.is_length_between?(
             params["name"],
             @name_min_length,
             @name_max_length,
             errs.name_invalid
           ),
         {:ok, _} <-
           ValidatorService.is_length_between?(
             params["username"],
             @username_min_length,
             @username_max_length,
             errs.username_invalid
           ),
         {:ok, _} <-
           ValidatorService.is_length_between?(
             params["secret"],
             @secret_min_length,
             @secret_max_length,
             errs.secret_invalid
           ),
         {:ok, _} <-
           ValidatorService.is_length_between?(
             params["slug"],
             @slug_min_length,
             @slug_max_length,
             errs.slug_invalid
           ),
         {:ok, _} <- ValidatorService.is_uuid?(project_uuid, errs.project_uuid_invalid),
         {:ok, _} <-
           ValidatorService.is_environment_slug_used?(
             params["slug"],
             project_uuid,
             nil,
             errs.slug_used
           ) do
      {:ok, ""}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_update_request(params, project_uuid, environment_uuid) do
    errs = %{
      name_required: "Environment name is required",
      name_invalid: "Environment name is invalid",
      username_required: "Environment username is required",
      username_invalid: "Environment username is invalid",
      secret_required: "Environment secret is required",
      secret_invalid: "Environment secret is invalid",
      slug_required: "Environment slug is required",
      slug_invalid: "Environment slug is invalid",
      slug_used: "Environment slug is already used",
      project_uuid_invalid: "Project ID is invalid"
    }

    with {:ok, _} <- ValidatorService.is_string?(params["name"], errs.name_required),
         {:ok, _} <- ValidatorService.is_string?(params["username"], errs.username_required),
         {:ok, _} <- ValidatorService.is_string?(params["secret"], errs.secret_required),
         {:ok, _} <- ValidatorService.is_string?(params["slug"], errs.slug_required),
         {:ok, _} <-
           ValidatorService.is_length_between?(
             params["name"],
             @name_min_length,
             @name_max_length,
             errs.name_invalid
           ),
         {:ok, _} <-
           ValidatorService.is_length_between?(
             params["username"],
             @username_min_length,
             @username_max_length,
             errs.username_invalid
           ),
         {:ok, _} <-
           ValidatorService.is_length_between?(
             params["secret"],
             @secret_min_length,
             @secret_max_length,
             errs.secret_invalid
           ),
         {:ok, _} <-
           ValidatorService.is_length_between?(
             params["slug"],
             @slug_min_length,
             @slug_max_length,
             errs.slug_invalid
           ),
         {:ok, _} <- ValidatorService.is_uuid?(project_uuid, errs.project_uuid_invalid),
         {:ok, _} <-
           ValidatorService.is_environment_slug_used?(
             params["slug"],
             project_uuid,
             environment_uuid,
             errs.slug_used
           ) do
      {:ok, ""}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end

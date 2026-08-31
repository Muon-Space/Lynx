# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.WorkspaceController do
  @moduledoc """
  Workspace Controller
  """

  use LynxWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Lynx.Context.WorkspaceContext
  alias Lynx.Context.ProjectContext
  alias Lynx.Context.TeamContext
  alias Lynx.Context.AuditContext
  alias Lynx.Service.ValidatorService
  alias LynxWeb.Schemas

  require Logger

  @name_min_length 2
  @name_max_length 60
  @description_min_length 2
  @description_max_length 250
  @slug_min_length 2
  @slug_max_length 60

  @default_list_limit 10
  @default_list_offset 0

  plug :regular_user when action in [:list]
  plug :super_user when action in [:index, :create, :update, :delete]

  tags(["Workspaces"])
  security([%{"api_key" => []}])

  operation(:list,
    summary: "List workspaces",
    description:
      "Super users see every workspace. Regular users only see workspaces " <>
        "containing at least one project owned by one of their teams. " <>
        "Pass `slug` to look a single workspace up without paging the whole " <>
        "collection; the response envelope is unchanged and holds zero or one " <>
        "workspace, subject to the same visibility rules.",
    parameters: [
      limit: [in: :query, type: :integer, description: "Default 10"],
      offset: [in: :query, type: :integer, description: "Default 0"],
      slug: [
        in: :query,
        type: :string,
        description: "Return only the workspace with this exact slug"
      ]
    ],
    responses: [
      ok: {"Workspaces", "application/json", Schemas.WorkspaceList},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:create,
    summary: "Create a workspace (super only)",
    request_body: {"Workspace", "application/json", Schemas.WorkspaceCreate},
    responses: [
      created: {"Created", "application/json", Schemas.Workspace},
      bad_request: {"Validation error", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:index,
    summary: "Get a workspace by UUID (super only)",
    parameters: [uuid: [in: :path, required: true, type: :string]],
    responses: [
      ok: {"Workspace", "application/json", Schemas.Workspace},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:update,
    summary: "Update a workspace (super only)",
    parameters: [uuid: [in: :path, required: true, type: :string]],
    request_body: {"Workspace", "application/json", Schemas.WorkspaceCreate},
    responses: [
      ok: {"Workspace", "application/json", Schemas.Workspace},
      bad_request: {"Validation error", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:delete,
    summary: "Delete a workspace (super only)",
    description:
      "Refuses with 400 while the workspace still holds projects. Reassign " <>
        "or delete those projects first — deleting the workspace also " <>
        "deletes every policy scoped to it.",
    parameters: [uuid: [in: :path, required: true, type: :string]],
    responses: [
      no_content: "Workspace deleted",
      bad_request: {"Workspace is not empty", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  defp super_user(conn, _opts) do
    Logger.info("Validate user permissions")

    if not conn.assigns[:is_super] do
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

  @doc """
  List Action Endpoint
  """
  def list(conn, params) do
    # Query params arrive as strings. The non-super branch slices in memory, and
    # Enum.slice/3 raises on a binary offset or limit, so coerce before use.
    limit = parse_int(params["limit"], @default_list_limit)
    offset = parse_int(params["offset"], @default_list_offset)

    {workspaces, count} =
      case params["slug"] do
        slug when is_binary(slug) and slug != "" ->
          workspaces_by_slug(conn, slug, offset, limit)

        _ ->
          if conn.assigns[:is_super] do
            {WorkspaceContext.get_workspaces(offset, limit), WorkspaceContext.count_workspaces()}
          else
            visible_workspaces(conn.assigns[:user_id], offset, limit)
          end
      end

    render(conn, "list.json", %{
      workspaces: workspaces,
      metadata: %{
        limit: limit,
        offset: offset,
        totalCount: count
      }
    })
  end

  @doc """
  Create Action Endpoint
  """
  def create(conn, params) do
    case validate_create_request(params) do
      {:ok, _} ->
        attrs =
          WorkspaceContext.new_workspace(%{
            name: params["name"],
            slug: params["slug"],
            description: params["description"]
          })

        case WorkspaceContext.create_workspace(attrs) do
          {:ok, workspace} ->
            AuditContext.log(conn, "created", "workspace", workspace.uuid, workspace.name)

            conn
            |> put_status(:created)
            |> render(:index, %{workspace: workspace})

          {:error, changeset} ->
            conn
            |> put_status(:bad_request)
            |> render(:error, %{message: changeset_error(changeset)})
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
  def index(conn, %{"uuid" => uuid}) do
    case WorkspaceContext.get_workspace_by_uuid(uuid) do
      nil ->
        conn
        |> put_status(:not_found)
        |> render(:error, %{message: "Workspace with ID #{uuid} not found"})

      workspace ->
        conn
        |> put_status(:ok)
        |> render(:index, %{workspace: workspace})
    end
  end

  @doc """
  Update Action Endpoint
  """
  def update(conn, %{"uuid" => uuid} = params) do
    case WorkspaceContext.get_workspace_by_uuid(uuid) do
      nil ->
        conn
        |> put_status(:not_found)
        |> render(:error, %{message: "Workspace with ID #{uuid} not found"})

      workspace ->
        do_update(conn, workspace, params)
    end
  end

  defp do_update(conn, workspace, params) do
    case validate_update_request(params, workspace.uuid) do
      {:ok, _} ->
        attrs = %{
          name: params["name"],
          slug: params["slug"],
          description: params["description"]
        }

        case WorkspaceContext.update_workspace(workspace, attrs) do
          {:ok, workspace} ->
            AuditContext.log(conn, "updated", "workspace", workspace.uuid, workspace.name)

            conn
            |> put_status(:ok)
            |> render(:index, %{workspace: workspace})

          {:error, changeset} ->
            conn
            |> put_status(:bad_request)
            |> render(:error, %{message: changeset_error(changeset)})
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
  def delete(conn, %{"uuid" => uuid}) do
    Logger.info("Attempt to delete workspace with uuid #{uuid}")

    case WorkspaceContext.get_workspace_by_uuid(uuid) do
      nil ->
        Logger.info("Workspace with uuid #{uuid} not found")

        conn
        |> put_status(:not_found)
        |> render(:error, %{message: "Workspace with ID #{uuid} not found"})

      workspace ->
        delete_if_empty(conn, workspace)
    end
  end

  # A workspace is the root of the project -> environment -> state tree, so
  # deleting a non-empty one is never a safe default. `projects.workspace_id`
  # is `on_delete: :nothing`, so the database would simply reject the delete
  # with a foreign-key error, while `policies.workspace_id` is
  # `on_delete: :delete_all` and would silently drop every policy scoped to
  # the workspace. Rather than surface a constraint error or orphan projects
  # by nulling them out, refuse and make the caller empty the workspace first.
  defp delete_if_empty(conn, workspace) do
    case ProjectContext.count_projects_by_workspace(workspace.id) do
      0 ->
        WorkspaceContext.delete_workspace(workspace)
        AuditContext.log(conn, "deleted", "workspace", workspace.uuid, workspace.name)

        Logger.info("Workspace with uuid #{workspace.uuid} is deleted")

        conn
        |> send_resp(:no_content, "")

      count ->
        Logger.info("Workspace with uuid #{workspace.uuid} still has #{count} project(s)")

        conn
        |> put_status(:bad_request)
        |> render(:error, %{
          message:
            "Workspace still has #{count} project(s). " <>
              "Move or delete them before deleting the workspace"
        })
    end
  end

  # Regular users only see workspaces holding at least one project owned by
  # one of their teams, mirroring the admin workspaces view. Workspaces are a
  # small top-level collection, so the visible set is built with one bounded
  # read and paginated in memory to keep `totalCount` accurate.
  defp visible_workspaces(user_id, offset, limit) do
    team_ids = user_team_ids(user_id)

    visible =
      WorkspaceContext.get_workspaces(0, LynxWeb.Limits.child_collection_max())
      |> Enum.filter(fn workspace ->
        ProjectContext.count_projects_by_workspace_and_teams(workspace.id, team_ids) > 0
      end)

    {Enum.slice(visible, offset, limit), length(visible)}
  end

  # Exact-slug lookup. This is a shortcut for "page the list and filter
  # client-side", so it has to be exactly as visible-restricted as the list it
  # replaces: the match is run through the same predicate as the unfiltered
  # regular-user branch, and a workspace the caller could not have listed is
  # dropped before it ever reaches the view. Limit/offset keep their normal
  # meaning — `totalCount` is the number of matches (0 or 1) and the returned
  # page is the requested window over it — so one decoder works either way.
  defp workspaces_by_slug(conn, slug, offset, limit) do
    matches =
      case WorkspaceContext.get_workspace_by_slug(slug) do
        nil -> []
        workspace -> if workspace_visible?(conn, workspace), do: [workspace], else: []
      end

    {Enum.slice(matches, offset, limit), length(matches)}
  end

  defp workspace_visible?(conn, workspace) do
    if conn.assigns[:is_super] do
      true
    else
      team_ids = user_team_ids(conn.assigns[:user_id])
      ProjectContext.count_projects_by_workspace_and_teams(workspace.id, team_ids) > 0
    end
  end

  defp user_team_ids(user_id) do
    user_id
    |> TeamContext.get_user_teams()
    |> Enum.map(& &1.id)
  end

  defp changeset_error(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)
    |> Enum.at(0, "Invalid workspace")
  end

  defp validate_create_request(params) do
    errs = validation_errors()

    with {:ok, _} <- validate_fields(params, errs),
         {:ok, _} <- ValidatorService.is_workspace_slug_used?(params["slug"], nil, errs.slug_used) do
      {:ok, ""}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_update_request(params, workspace_uuid) do
    errs = validation_errors()

    with {:ok, _} <- validate_fields(params, errs),
         {:ok, _} <-
           ValidatorService.is_workspace_slug_used?(
             params["slug"],
             workspace_uuid,
             errs.slug_used
           ) do
      {:ok, ""}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validation_errors do
    %{
      name_required: "Workspace name is required",
      name_invalid: "Workspace name is invalid",
      description_required: "Workspace description is required",
      description_invalid: "Workspace description is invalid",
      slug_required: "Workspace slug is required",
      slug_invalid: "Workspace slug is invalid",
      slug_used: "Workspace slug is already used"
    }
  end

  defp validate_fields(params, errs) do
    with {:ok, _} <- ValidatorService.is_string?(params["name"], errs.name_required),
         {:ok, _} <-
           ValidatorService.is_string?(params["description"], errs.description_required),
         {:ok, _} <- ValidatorService.is_string?(params["slug"], errs.slug_required),
         {:ok, _} <- ValidatorService.is_not_empty?(params["name"], errs.name_invalid),
         {:ok, _} <-
           ValidatorService.is_not_empty?(params["description"], errs.description_invalid),
         {:ok, _} <- ValidatorService.is_not_empty?(params["slug"], errs.slug_invalid),
         {:ok, _} <-
           ValidatorService.is_length_between?(
             params["name"],
             @name_min_length,
             @name_max_length,
             errs.name_invalid
           ),
         {:ok, _} <-
           ValidatorService.is_length_between?(
             params["description"],
             @description_min_length,
             @description_max_length,
             errs.description_invalid
           ),
         {:ok, _} <-
           ValidatorService.is_length_between?(
             params["slug"],
             @slug_min_length,
             @slug_max_length,
             errs.slug_invalid
           ) do
      {:ok, ""}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Query params are strings; internal callers pass integers. Mirrors the
  # helper in AuditController. Negative values are clamped to zero because both
  # in-memory branches feed these to `Enum.slice/3`, which raises on a negative
  # amount.
  defp parse_int(nil, default), do: max(default, 0)

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> max(n, 0)
      :error -> max(default, 0)
    end
  end

  defp parse_int(val, _) when is_integer(val), do: max(val, 0)

  defp parse_int(_, default), do: max(default, 0)
end

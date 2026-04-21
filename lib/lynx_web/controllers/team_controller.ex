# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.TeamController do
  @moduledoc """
  Team Controller
  """

  use LynxWeb, :controller
  use OpenApiSpex.ControllerSpecs

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

  tags(["Teams"])
  security([%{"api_key" => []}])

  operation(:list,
    summary: "List teams",
    parameters: [
      limit: [in: :query, type: :integer, description: "Default 10"],
      offset: [in: :query, type: :integer, description: "Default 0"]
    ],
    responses: [
      ok: {"Teams", "application/json", Schemas.TeamList},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:create,
    summary: "Create a team (super only)",
    request_body: {"Team", "application/json", Schemas.TeamCreate},
    responses: [
      created: {"Created", "application/json", Schemas.Team},
      bad_request: {"Validation error", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:index,
    summary: "Get a team by UUID (super only)",
    parameters: [uuid: [in: :path, required: true, type: :string]],
    responses: [
      ok: {"Team", "application/json", Schemas.Team},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:update,
    summary: "Update a team (super only)",
    parameters: [uuid: [in: :path, required: true, type: :string]],
    request_body: {"Team", "application/json", Schemas.TeamCreate},
    responses: [
      ok: {"Team", "application/json", Schemas.Team},
      bad_request: {"Validation error", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:delete,
    summary: "Delete a team (super only)",
    parameters: [uuid: [in: :path, required: true, type: :string]],
    responses: [
      no_content: "Team deleted",
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
    limit = params["limit"] || @default_list_limit
    offset = params["offset"] || @default_list_offset

    {teams, count} =
      if conn.assigns[:is_super] do
        {TeamContext.get_teams(offset, limit), TeamContext.count_teams()}
      else
        {TeamContext.get_user_teams_paged(conn.assigns[:user_id], offset, limit),
         TeamContext.count_user_teams(conn.assigns[:user_id])}
      end

    render(conn, "list.json", %{
      teams: teams,
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
        result =
          TeamContext.create_team_from_data(%{
            slug: params["slug"],
            name: params["name"],
            description: params["description"]
          })

        case result do
          {:ok, team} ->
            TeamContext.sync_team_members(team.id, params["members"])
            AuditContext.log(conn, "created", "team", team.uuid, team.name)

            conn
            |> put_status(:created)
            |> render(:index, %{team: team})

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
  def index(conn, %{"uuid" => uuid}) do
    case TeamContext.fetch_team_by_uuid(uuid) do
      {:not_found, msg} ->
        conn
        |> put_status(:not_found)
        |> render(:error, %{message: msg})

      {:ok, team} ->
        conn
        |> put_status(:ok)
        |> render(:index, %{team: team})
    end
  end

  @doc """
  Update Action Endpoint
  """
  def update(conn, params) do
    case validate_update_request(params, params["uuid"]) do
      {:ok, _} ->
        result =
          TeamContext.update_team_from_data(%{
            uuid: params["uuid"],
            slug: params["slug"],
            name: params["name"],
            description: params["description"]
          })

        case result do
          {:ok, team} ->
            TeamContext.sync_team_members(team.id, params["members"])

            conn
            |> put_status(:ok)
            |> render(:index, %{team: team})

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
  def delete(conn, %{"uuid" => uuid}) do
    Logger.info("Attempt to delete team with uuid #{uuid}")

    case TeamContext.delete_team_by_uuid(uuid) do
      {:not_found, msg} ->
        Logger.info("Team with uuid #{uuid} not found")

        conn
        |> put_status(:not_found)
        |> render(:error, %{message: msg})

      {:ok, _} ->
        Logger.info("Team with uuid #{uuid} is deleted")

        conn
        |> send_resp(:no_content, "")
    end
  end

  defp validate_create_request(params) do
    errs = %{
      name_required: "Team name is required",
      name_invalid: "Team name is invalid",
      description_required: "Team description is required",
      description_invalid: "Team description is invalid",
      slug_required: "Team slug is required",
      slug_invalid: "Team slug is invalid",
      slug_used: "Team slug is already used",
      members_invalid: "Team members are required"
    }

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
           ),
         {:ok, _} <- ValidatorService.is_team_slug_used?(params["slug"], nil, errs.slug_used),
         {:ok, _} <- ValidatorService.is_list?(params["members"], errs.members_invalid),
         {:ok, _} <- ValidatorService.is_not_empty_list?(params["members"], errs.members_invalid) do
      {:ok, ""}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_update_request(params, team_uuid) do
    errs = %{
      name_required: "Team name is required",
      name_invalid: "Team name is invalid",
      description_required: "Team description is required",
      description_invalid: "Team description is invalid",
      slug_required: "Team slug is required",
      slug_invalid: "Team slug is invalid",
      slug_used: "Team slug is already used",
      members_invalid: "Team members are required"
    }

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
           ),
         {:ok, _} <-
           ValidatorService.is_team_slug_used?(params["slug"], team_uuid, errs.slug_used),
         {:ok, _} <- ValidatorService.is_list?(params["members"], errs.members_invalid),
         {:ok, _} <- ValidatorService.is_not_empty_list?(params["members"], errs.members_invalid) do
      {:ok, ""}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.SCIMController do
  @moduledoc """
  SCIM 2.0 Controller - implements RFC 7644 endpoints
  """

  use LynxWeb, :controller

  alias Lynx.Service.SCIM
  alias Lynx.Context.AuditContext
  alias Lynx.Service.SCIMService

  # -- Discovery --

  def service_provider_config(conn, _params) do
    conn
    |> put_scim_content_type()
    |> json(SCIMService.service_provider_config())
  end

  def resource_types(conn, _params) do
    conn
    |> put_scim_content_type()
    |> json(SCIMService.resource_types())
  end

  def schemas(conn, _params) do
    conn
    |> put_scim_content_type()
    |> json(SCIMService.schemas())
  end

  # -- Users --

  def list_users(conn, params) do
    filter = SCIMService.parse_filter(params["filter"])
    start_index = parse_int(params["startIndex"], 1)
    count = parse_int(params["count"], 100)

    {users, total} = SCIM.list_users(filter, start_index, count)

    resources = Enum.map(users, &SCIMService.format_user_resource/1)

    conn
    |> put_scim_content_type()
    |> json(SCIMService.format_list_response(resources, total, start_index))
  end

  def create_user(conn, params) do
    case SCIMService.parse_user_resource(params) do
      {:ok, attrs} ->
        case SCIM.create_user(attrs) do
          {:ok, user} ->
            AuditContext.log_system("created", "user", user.uuid, user.name, %{source: "scim"})

            conn
            |> put_scim_content_type()
            |> put_status(:created)
            |> put_resp_header("location", "/scim/v2/Users/#{user.uuid}")
            |> json(SCIMService.format_user_resource(user))

          {:error, msg} when is_binary(msg) ->
            conn
            |> put_scim_content_type()
            |> put_status(:conflict)
            |> json(SCIMService.format_error(409, msg))

          {:error, error} ->
            conn
            |> put_scim_content_type()
            |> put_status(:bad_request)
            |> json(SCIMService.format_error(400, inspect(error)))
        end

      {:error, error} ->
        conn
        |> put_scim_content_type()
        |> put_status(:bad_request)
        |> json(error)
    end
  end

  def get_user(conn, %{"id" => uuid}) do
    case SCIM.get_user(uuid) do
      {:ok, user} ->
        conn
        |> put_scim_content_type()
        |> json(SCIMService.format_user_resource(user))

      {:not_found, _} ->
        conn
        |> put_scim_content_type()
        |> put_status(:not_found)
        |> json(SCIMService.format_error(404, "User not found"))
    end
  end

  def update_user(conn, %{"id" => uuid} = params) do
    case SCIMService.parse_user_resource(params) do
      {:ok, attrs} ->
        case SCIM.update_user(uuid, attrs) do
          {:ok, user} ->
            AuditContext.log_system("updated", "user", user.uuid, user.name, %{source: "scim"})

            conn
            |> put_scim_content_type()
            |> json(SCIMService.format_user_resource(user))

          {:not_found, _} ->
            conn
            |> put_scim_content_type()
            |> put_status(:not_found)
            |> json(SCIMService.format_error(404, "User not found"))

          {:error, msg} ->
            conn
            |> put_scim_content_type()
            |> put_status(:bad_request)
            |> json(SCIMService.format_error(400, inspect(msg)))
        end

      {:error, error} ->
        conn
        |> put_scim_content_type()
        |> put_status(:bad_request)
        |> json(error)
    end
  end

  def patch_user(conn, %{"id" => uuid} = params) do
    case SCIMService.parse_patch_operations(params) do
      {:ok, operations} ->
        case SCIM.patch_user(uuid, operations) do
          {:ok, user} ->
            AuditContext.log_system("updated", "user", user.uuid, user.name, %{
              source: "scim",
              method: "patch"
            })

            conn
            |> put_scim_content_type()
            |> json(SCIMService.format_user_resource(user))

          {:not_found, _} ->
            conn
            |> put_scim_content_type()
            |> put_status(:not_found)
            |> json(SCIMService.format_error(404, "User not found"))

          {:error, msg} ->
            conn
            |> put_scim_content_type()
            |> put_status(:bad_request)
            |> json(SCIMService.format_error(400, inspect(msg)))
        end

      {:error, error} ->
        conn
        |> put_scim_content_type()
        |> put_status(:bad_request)
        |> json(error)
    end
  end

  def delete_user(conn, %{"id" => uuid}) do
    case SCIM.delete_user(uuid) do
      :ok ->
        AuditContext.log_system("deleted", "user", uuid, nil, %{source: "scim"})
        send_resp(conn, :no_content, "")

      {:not_found, _} ->
        conn
        |> put_scim_content_type()
        |> put_status(:not_found)
        |> json(SCIMService.format_error(404, "User not found"))
    end
  end

  # -- Groups --

  def list_groups(conn, params) do
    filter = SCIMService.parse_filter(params["filter"])
    start_index = parse_int(params["startIndex"], 1)
    count = parse_int(params["count"], 100)

    {teams, total} = SCIM.list_groups(filter, start_index, count)

    resources = Enum.map(teams, &SCIMService.format_group_resource/1)

    conn
    |> put_scim_content_type()
    |> json(SCIMService.format_list_response(resources, total, start_index))
  end

  def create_group(conn, params) do
    case SCIMService.parse_group_resource(params) do
      {:ok, attrs} ->
        case SCIM.create_group(attrs) do
          {:ok, team} ->
            AuditContext.log_system("created", "team", team.uuid, team.name, %{source: "scim"})

            conn
            |> put_scim_content_type()
            |> put_status(:created)
            |> put_resp_header("location", "/scim/v2/Groups/#{team.uuid}")
            |> json(SCIMService.format_group_resource(team))

          {:error, msg} ->
            conn
            |> put_scim_content_type()
            |> put_status(:conflict)
            |> json(SCIMService.format_error(409, inspect(msg)))
        end

      {:error, error} ->
        conn
        |> put_scim_content_type()
        |> put_status(:bad_request)
        |> json(error)
    end
  end

  def get_group(conn, %{"id" => uuid}) do
    case SCIM.get_group(uuid) do
      {:ok, team} ->
        conn
        |> put_scim_content_type()
        |> json(SCIMService.format_group_resource(team))

      {:not_found, _} ->
        conn
        |> put_scim_content_type()
        |> put_status(:not_found)
        |> json(SCIMService.format_error(404, "Group not found"))
    end
  end

  def update_group(conn, %{"id" => uuid} = params) do
    case SCIMService.parse_group_resource(params) do
      {:ok, attrs} ->
        case SCIM.update_group(uuid, attrs) do
          {:ok, team} ->
            AuditContext.log_system("updated", "team", team.uuid, team.name, %{source: "scim"})

            conn
            |> put_scim_content_type()
            |> json(SCIMService.format_group_resource(team))

          {:not_found, _} ->
            conn
            |> put_scim_content_type()
            |> put_status(:not_found)
            |> json(SCIMService.format_error(404, "Group not found"))

          {:error, msg} ->
            conn
            |> put_scim_content_type()
            |> put_status(:bad_request)
            |> json(SCIMService.format_error(400, inspect(msg)))
        end

      {:error, error} ->
        conn
        |> put_scim_content_type()
        |> put_status(:bad_request)
        |> json(error)
    end
  end

  def patch_group(conn, %{"id" => uuid} = params) do
    case SCIMService.parse_patch_operations(params) do
      {:ok, operations} ->
        case SCIM.patch_group(uuid, operations) do
          {:ok, team} ->
            AuditContext.log_system("updated", "team", team.uuid, team.name, %{
              source: "scim",
              method: "patch"
            })

            conn
            |> put_scim_content_type()
            |> json(SCIMService.format_group_resource(team))

          {:not_found, _} ->
            conn
            |> put_scim_content_type()
            |> put_status(:not_found)
            |> json(SCIMService.format_error(404, "Group not found"))
        end

      {:error, error} ->
        conn
        |> put_scim_content_type()
        |> put_status(:bad_request)
        |> json(error)
    end
  end

  def delete_group(conn, %{"id" => uuid}) do
    case SCIM.delete_group(uuid) do
      :ok ->
        AuditContext.log_system("deleted", "team", uuid, nil, %{source: "scim"})
        send_resp(conn, :no_content, "")

      {:not_found, _} ->
        conn
        |> put_scim_content_type()
        |> put_status(:not_found)
        |> json(SCIMService.format_error(404, "Group not found"))
    end
  end

  # -- Helpers --

  defp put_scim_content_type(conn) do
    put_resp_content_type(conn, "application/scim+json")
  end

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val
end

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Service.SCIMService do
  @moduledoc """
  SCIM 2.0 Service - JSON parsing and formatting per RFC 7643/7644
  """

  alias Lynx.Service.SCIM
  alias Lynx.Context.TeamContext

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @group_schema "urn:ietf:params:scim:schemas:core:2.0:Group"
  @list_schema "urn:ietf:params:scim:api:messages:2.0:ListResponse"
  @sp_config_schema "urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"
  @resource_type_schema "urn:ietf:params:scim:schemas:core:2.0:ResourceType"
  @schema_schema "urn:ietf:params:scim:schemas:core:2.0:Schema"
  @error_schema "urn:ietf:params:scim:api:messages:2.0:Error"

  # -- Parsing --

  @doc """
  Parse a SCIM User resource from request body
  """
  def parse_user_resource(body) do
    email =
      body["userName"] ||
        get_in(body, ["emails", Access.at(0), "value"])

    name =
      if body["name"] do
        SCIM.format_scim_name(body["name"])
      else
        body["displayName"] || email
      end

    case email do
      nil ->
        {:error, format_error(400, "userName or emails[0].value is required")}

      _ ->
        # Only put `:is_active` in attrs when the body actually carries
        # `active`. Defaulting to `true` here silently flips deactivated
        # users back to active on a PUT that omits the attribute — the
        # downstream `Map.get(attrs, :is_active, user.is_active)` in
        # `SCIM.update_user/2` already handles the create-vs-preserve
        # distinction correctly when the key is absent.
        attrs = %{
          email: email,
          name: name,
          external_id: body["externalId"]
        }

        attrs =
          if Map.has_key?(body, "active"),
            do: Map.put(attrs, :is_active, body["active"]),
            else: attrs

        {:ok, attrs}
    end
  end

  @doc """
  Parse a SCIM Group resource from request body
  """
  def parse_group_resource(body) do
    display_name = body["displayName"]

    case display_name do
      nil ->
        {:error, format_error(400, "displayName is required")}

      _ ->
        members =
          case body["members"] do
            nil -> nil
            members when is_list(members) -> members
            _ -> nil
          end

        {:ok,
         %{
           display_name: display_name,
           description: body["description"],
           external_id: body["externalId"],
           members: members
         }}
    end
  end

  @doc """
  Parse SCIM PATCH operations
  """
  def parse_patch_operations(body) do
    case body["Operations"] do
      nil ->
        {:error, format_error(400, "Operations is required")}

      ops when is_list(ops) ->
        {:ok, ops}

      _ ->
        {:error, format_error(400, "Operations must be an array")}
    end
  end

  @doc """
  Parse a SCIM filter string (basic support for eq operator)
  """
  def parse_filter(nil), do: nil
  def parse_filter(""), do: nil

  def parse_filter(filter_string) do
    case Regex.run(~r/^(\w+)\s+eq\s+"([^"]*)"$/, filter_string) do
      [_, attr, value] -> %{attr: attr, value: value}
      _ -> nil
    end
  end

  # -- Formatting --

  @doc """
  Format a user as a SCIM User resource
  """
  def format_user_resource(user) do
    %{
      "schemas" => [@user_schema],
      "id" => user.uuid,
      # `externalId` is the IdP's SCIM-side identifier — pulled from
      # the linked `user_identities` row rather than the deprecated
      # `users.external_id` column.
      "externalId" => scim_external_id(user),
      "userName" => user.email,
      "name" => %{
        "formatted" => user.name
      },
      "emails" => [
        %{
          "value" => user.email,
          "primary" => true
        }
      ],
      "active" => user.is_active,
      "meta" => %{
        "resourceType" => "User",
        "created" => format_datetime(user.inserted_at),
        "lastModified" => format_datetime(user.updated_at),
        "location" => "/scim/v2/Users/#{user.uuid}"
      }
    }
  end

  defp scim_external_id(user) do
    case Lynx.Context.UserIdentityContext.list_identities_for_user(user.id) do
      [] ->
        nil

      identities ->
        case Enum.find(identities, &(&1.provider == "scim")) do
          nil -> nil
          identity -> identity.provider_uid
        end
    end
  end

  @doc """
  Format a team as a SCIM Group resource
  """
  def format_group_resource(team) do
    members = TeamContext.get_team_members(team.id)

    member_list =
      Enum.map(members, fn member_uuid ->
        %{
          "value" => member_uuid,
          "$ref" => "/scim/v2/Users/#{member_uuid}",
          "type" => "User"
        }
      end)

    %{
      "schemas" => [@group_schema],
      "id" => team.uuid,
      "externalId" => team.external_id,
      "displayName" => team.name,
      "members" => member_list,
      "meta" => %{
        "resourceType" => "Group",
        "created" => format_datetime(team.inserted_at),
        "lastModified" => format_datetime(team.updated_at),
        "location" => "/scim/v2/Groups/#{team.uuid}"
      }
    }
  end

  @doc """
  Format a SCIM list response
  """
  def format_list_response(resources, total_count, start_index) do
    %{
      "schemas" => [@list_schema],
      "totalResults" => total_count,
      "startIndex" => start_index,
      "itemsPerPage" => length(resources),
      "Resources" => resources
    }
  end

  @doc """
  Format a SCIM error response
  """
  def format_error(status, detail) do
    %{
      "schemas" => [@error_schema],
      "status" => to_string(status),
      "detail" => detail
    }
  end

  @doc """
  ServiceProviderConfig response
  """
  def service_provider_config do
    %{
      "schemas" => [@sp_config_schema],
      "patch" => %{"supported" => true},
      "bulk" => %{"supported" => false, "maxOperations" => 0, "maxPayloadSize" => 0},
      "filter" => %{"supported" => true, "maxResults" => 200},
      "changePassword" => %{"supported" => false},
      "sort" => %{"supported" => false},
      "etag" => %{"supported" => false},
      "authenticationSchemes" => [
        %{
          "type" => "oauthbearertoken",
          "name" => "OAuth Bearer Token",
          "description" => "Authentication scheme using the OAuth Bearer Token Standard"
        }
      ]
    }
  end

  @doc """
  ResourceTypes response
  """
  def resource_types do
    [
      %{
        "schemas" => [@resource_type_schema],
        "id" => "User",
        "name" => "User",
        "endpoint" => "/scim/v2/Users",
        "schema" => @user_schema
      },
      %{
        "schemas" => [@resource_type_schema],
        "id" => "Group",
        "name" => "Group",
        "endpoint" => "/scim/v2/Groups",
        "schema" => @group_schema
      }
    ]
  end

  @doc """
  Schemas response
  """
  def schemas do
    [
      %{
        "schemas" => [@schema_schema],
        "id" => @user_schema,
        "name" => "User",
        "description" => "User Account"
      },
      %{
        "schemas" => [@schema_schema],
        "id" => @group_schema,
        "name" => "Group",
        "description" => "Group"
      }
    ]
  end

  defp format_datetime(nil), do: nil

  defp format_datetime(dt) do
    DateTime.from_naive!(dt, "Etc/UTC")
    |> DateTime.to_iso8601()
  end
end

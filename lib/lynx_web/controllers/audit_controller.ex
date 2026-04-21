# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.AuditController do
  @moduledoc """
  Audit Controller
  """

  use LynxWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Lynx.Context.AuditContext
  alias LynxWeb.Schemas

  plug :super_user

  tags(["Audit"])
  security([%{"api_key" => []}])

  operation(:list,
    summary: "List audit events (super only)",
    description: "All filter params are optional and AND-combined.",
    parameters: [
      action: [in: :query, type: :string, description: "Exact action match"],
      resource_type: [in: :query, type: :string, description: "Exact resource type match"],
      actor_id: [in: :query, type: :integer, description: "Exact actor PK"],
      limit: [in: :query, type: :integer, description: "Default 50"],
      offset: [in: :query, type: :integer, description: "Default 0"]
    ],
    responses: [
      ok: {"Events", "application/json", Schemas.AuditEventList},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  defp super_user(conn, _opts) do
    if not conn.assigns[:is_super] do
      conn
      |> put_status(:forbidden)
      |> json(%{errorMessage: "Forbidden Access"})
      |> halt
    else
      conn
    end
  end

  def list(conn, params) do
    opts = %{
      offset: parse_int(params["offset"], 0),
      limit: parse_int(params["limit"], 50),
      action: params["action"],
      resource_type: params["resource_type"],
      actor_id: params["actor_id"]
    }

    {events, total} = AuditContext.list_events(opts)

    conn
    |> json(%{
      events:
        Enum.map(events, fn e ->
          %{
            id: e.uuid,
            actorId: e.actor_id,
            actorName: e.actor_name,
            actorType: e.actor_type,
            action: e.action,
            resourceType: e.resource_type,
            resourceId: e.resource_id,
            resourceName: e.resource_name,
            metadata: if(e.metadata, do: Jason.decode!(e.metadata), else: nil),
            createdAt: e.inserted_at
          }
        end),
      _metadata: %{
        offset: opts.offset,
        limit: opts.limit,
        totalCount: total
      }
    })
  end

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(val, _) when is_integer(val), do: val
end

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.AuditController do
  @moduledoc """
  Audit Controller
  """

  use LynxWeb, :controller

  alias Lynx.Module.AuditModule

  plug :super_user

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

    {events, total} = AuditModule.list_events(opts)

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

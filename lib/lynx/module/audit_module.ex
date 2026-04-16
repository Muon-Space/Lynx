# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Module.AuditModule do
  @moduledoc """
  Audit Module - logs user actions for audit trail.

  Usage:
    AuditModule.log(conn, "created", "environment", env.uuid, env.name)
    AuditModule.log(conn, "updated", "project", project.uuid, project.name, %{slug: "new-slug"})
  """

  alias Lynx.Context.AuditContext

  @doc """
  Log an audit event from a Plug.Conn (extracts actor from assigns).
  """
  def log(conn, action, resource_type, resource_id \\ nil, resource_name \\ nil, metadata \\ nil) do
    attrs = %{
      actor_id: conn.assigns[:user_id],
      actor_name: conn.assigns[:user_name] || "system",
      actor_type: "user",
      action: action,
      resource_type: resource_type,
      resource_id: to_string_or_nil(resource_id),
      resource_name: resource_name,
      metadata: encode_metadata(metadata)
    }

    AuditContext.create_event(attrs)
  end

  @doc """
  Log an audit event with explicit actor (for non-HTTP contexts like SCIM).
  """
  def log_system(action, resource_type, resource_id \\ nil, resource_name \\ nil, metadata \\ nil) do
    attrs = %{
      actor_id: nil,
      actor_name: "system",
      actor_type: "system",
      action: action,
      resource_type: resource_type,
      resource_id: to_string_or_nil(resource_id),
      resource_name: resource_name,
      metadata: encode_metadata(metadata)
    }

    AuditContext.create_event(attrs)
  end

  @doc """
  List audit events with optional filters.
  """
  def list_events(opts \\ %{}) do
    AuditContext.list_events(opts)
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(val), do: to_string(val)

  defp encode_metadata(nil), do: nil
  defp encode_metadata(meta) when is_map(meta), do: Jason.encode!(meta)
  defp encode_metadata(meta) when is_binary(meta), do: meta
end

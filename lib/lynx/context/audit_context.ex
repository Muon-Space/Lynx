# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Context.AuditContext do
  @moduledoc """
  Audit context — write/read audit events.

  ## Logging helpers

      AuditContext.log(conn, "created", "environment", env.uuid, env.name)
      AuditContext.log_user(user, "deleted", "team", team.uuid, team.name)
      AuditContext.log_system("state_pushed", "environment", env_path)
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.AuditEvent

  @doc """
  Insert a raw audit event. Prefer the higher-level helpers below.
  """
  def create_event(attrs) do
    %AuditEvent{}
    |> AuditEvent.changeset(Map.put(attrs, :uuid, Ecto.UUID.generate()))
    |> Repo.insert()
  end

  @doc """
  Log an audit event from a Plug.Conn (extracts actor from assigns).
  """
  def log(conn, action, resource_type, resource_id \\ nil, resource_name \\ nil, metadata \\ nil) do
    create_event(%{
      actor_id: conn.assigns[:user_id],
      actor_name: conn.assigns[:user_name] || "system",
      actor_type: "user",
      action: action,
      resource_type: resource_type,
      resource_id: to_string_or_nil(resource_id),
      resource_name: resource_name,
      metadata: encode_metadata(metadata)
    })
  end

  @doc """
  Log an audit event with explicit actor (for non-HTTP contexts like SCIM).
  """
  def log_user(
        user,
        action,
        resource_type,
        resource_id \\ nil,
        resource_name \\ nil,
        metadata \\ nil
      ) do
    create_event(%{
      actor_id: to_string_or_nil(user.id),
      actor_name: user.name,
      actor_type: "user",
      action: action,
      resource_type: resource_type,
      resource_id: to_string_or_nil(resource_id),
      resource_name: resource_name,
      metadata: encode_metadata(metadata)
    })
  end

  @doc """
  Log an audit event with no human actor (background workers, system tasks).
  """
  def log_system(action, resource_type, resource_id \\ nil, resource_name \\ nil, metadata \\ nil) do
    create_event(%{
      actor_id: nil,
      actor_name: "system",
      actor_type: "system",
      action: action,
      resource_type: resource_type,
      resource_id: to_string_or_nil(resource_id),
      resource_name: resource_name,
      metadata: encode_metadata(metadata)
    })
  end

  @doc """
  List audit events with optional filters: `:action`, `:resource_type`, `:actor_id`,
  `:limit`, `:offset`. Returns `{events, total_count}`.
  """
  def list_events(opts \\ %{}) do
    offset = Map.get(opts, :offset, 0)
    limit = Map.get(opts, :limit, 50)

    base_query =
      from(e in AuditEvent)
      |> maybe_filter(:action, opts[:action])
      |> maybe_filter(:resource_type, opts[:resource_type])
      |> maybe_filter(:actor_id, opts[:actor_id])

    total =
      base_query
      |> select([e], count(e.id))
      |> Repo.one()

    events =
      base_query
      |> order_by([e], desc: e.inserted_at)
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()

    {events, total}
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(val), do: to_string(val)

  defp encode_metadata(nil), do: nil
  defp encode_metadata(meta) when is_map(meta), do: Jason.encode!(meta)
  defp encode_metadata(meta) when is_binary(meta), do: meta

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query
  defp maybe_filter(query, :action, value), do: where(query, [e], e.action == ^value)

  defp maybe_filter(query, :resource_type, value),
    do: where(query, [e], e.resource_type == ^value)

  defp maybe_filter(query, :actor_id, value) when is_integer(value),
    do: where(query, [e], e.actor_id == ^value)

  defp maybe_filter(query, :actor_id, value) when is_binary(value) do
    case Integer.parse(value) do
      {id, _} -> where(query, [e], e.actor_id == ^id)
      :error -> query
    end
  end

  defp maybe_filter(query, _, _), do: query
end

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Context.AuditContext do
  @moduledoc """
  Audit Context Module
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.AuditEvent

  def create_event(attrs) do
    %AuditEvent{}
    |> AuditEvent.changeset(Map.put(attrs, :uuid, Ecto.UUID.generate()))
    |> Repo.insert()
  end

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

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
  List audit events with optional filters and pagination.

  ## Filters

    * `:action` — exact action match (`"created"`, `"deleted"`, ...)
    * `:resource_type` — exact resource type (`"project"`, `"environment"`, ...)
    * `:resource_id` — exact resource ID (string match)
    * `:actor_id` — exact actor primary key
    * `:actor` — substring match against the event's `actor_name`, the
      joined user's `email`, and the `actor_type` field. Uses a LEFT JOIN so
      system-actor events (`actor_id: nil`) still surface when the term
      matches their `actor_name` (`"system"`) or `actor_type` (`"system"`).
    * `:date_from` — events at or after this `DateTime`
    * `:date_to` — events at or before this `DateTime`

  Pagination via `:limit` (default 50) and `:offset` (default 0). All filters
  are AND-combined; nil/empty filter values are dropped.

  Returns `{events, total_count}`.
  """
  def list_events(opts \\ %{}) do
    offset = Map.get(opts, :offset, 0)
    limit = Map.get(opts, :limit, 50)

    base_query = filtered_query(opts)

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

  @doc """
  Stream every audit event matching `opts` as CSV rows. Wraps the matched
  set in a `Repo.transaction` so the underlying cursor stays open while the
  caller iterates — required for arbitrarily large exports without loading
  the whole result set into memory.

  Returns an `Enumerable` of CSV-encoded `iodata` chunks. Use as:

      Repo.transaction(fn ->
        AuditContext.stream_events_csv(opts)
        |> Enum.each(&IO.binwrite(io, &1))
      end)
  """
  def stream_events_csv(opts \\ %{}) do
    header =
      ~w(id action resource_type resource_id resource_name actor_id actor_name actor_type inserted_at metadata)

    header_row = NimbleCSV.RFC4180.dump_to_iodata([header])

    rows =
      filtered_query(opts)
      |> order_by([e], desc: e.inserted_at)
      |> Repo.stream()
      |> Stream.map(&event_to_csv_row/1)
      |> Stream.map(fn row -> NimbleCSV.RFC4180.dump_to_iodata([row]) end)

    Stream.concat([header_row], rows)
  end

  defp event_to_csv_row(e) do
    [
      to_string(e.id),
      to_string_or_blank(e.action),
      to_string_or_blank(e.resource_type),
      to_string_or_blank(e.resource_id),
      to_string_or_blank(e.resource_name),
      to_string_or_blank(e.actor_id),
      to_string_or_blank(e.actor_name),
      to_string_or_blank(e.actor_type),
      datetime_to_iso8601(e.inserted_at),
      to_string_or_blank(e.metadata)
    ]
  end

  defp to_string_or_blank(nil), do: ""
  defp to_string_or_blank(v), do: to_string(v)

  defp datetime_to_iso8601(nil), do: ""
  defp datetime_to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_to_iso8601(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  defp filtered_query(opts) do
    # Back-compat: callers still passing `:actor_email` get folded into the
    # broader `:actor` filter below.
    actor_term = opts[:actor] || opts[:actor_email]

    from(e in AuditEvent)
    |> maybe_filter(:action, opts[:action])
    |> maybe_filter(:resource_type, opts[:resource_type])
    |> maybe_filter(:resource_id, opts[:resource_id])
    |> maybe_filter(:actor_id, opts[:actor_id])
    |> maybe_filter(:date_from, opts[:date_from])
    |> maybe_filter(:date_to, opts[:date_to])
    |> maybe_filter_actor(actor_term)
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

  defp maybe_filter(query, :resource_id, value) when is_binary(value),
    do: where(query, [e], e.resource_id == ^value)

  defp maybe_filter(query, :actor_id, value) when is_integer(value),
    do: where(query, [e], e.actor_id == ^value)

  defp maybe_filter(query, :actor_id, value) when is_binary(value) do
    case Integer.parse(value) do
      {id, _} -> where(query, [e], e.actor_id == ^id)
      :error -> query
    end
  end

  defp maybe_filter(query, :date_from, %DateTime{} = dt),
    do: where(query, [e], e.inserted_at >= ^DateTime.to_naive(dt))

  defp maybe_filter(query, :date_to, %DateTime{} = dt),
    do: where(query, [e], e.inserted_at <= ^DateTime.to_naive(dt))

  defp maybe_filter(query, _, _), do: query

  defp maybe_filter_actor(query, nil), do: query
  defp maybe_filter_actor(query, ""), do: query

  defp maybe_filter_actor(query, term) when is_binary(term) do
    pattern = "%#{Lynx.Search.escape_like(term)}%"

    # LEFT JOIN preserves system-actor rows (actor_id: nil) so a search for
    # `"system"` still matches them via actor_name / actor_type.
    from(e in query,
      left_join: u in Lynx.Model.User,
      on: u.id == e.actor_id,
      where:
        ilike(e.actor_name, ^pattern) or
          ilike(e.actor_type, ^pattern) or
          ilike(u.email, ^pattern)
    )
  end
end

defmodule LynxWeb.AuditExportController do
  @moduledoc """
  Streams the current `/admin/audit` filter set as a CSV download.

  The filter params (`action`, `resource_type`, `resource_id`, `actor`,
  `from`, `to`) match the LV's URL state, so an admin can copy the filtered
  audit URL, change `/admin/audit?...` → `/admin/audit/export.csv?...`, and
  get the same set as a downloadable file.

  Auth: super only. Output is always streamed via `Repo.transaction` so
  arbitrarily large exports don't load into memory.
  """
  use LynxWeb, :controller

  require Logger

  alias Lynx.Context.AuditContext
  alias Lynx.Repo

  plug :super_only

  defp super_only(conn, _opts) do
    if conn.assigns[:user_role] == :super do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{errorMessage: "Forbidden"})
      |> halt()
    end
  end

  def export(conn, params) do
    opts = parse_filters(params)

    filename = "lynx-audit-#{Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")}.csv"

    conn =
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_chunked(200)

    {:ok, conn} =
      Repo.transaction(fn ->
        AuditContext.stream_events_csv(opts)
        |> Enum.reduce_while(conn, fn chunk, acc_conn ->
          case Plug.Conn.chunk(acc_conn, chunk) do
            {:ok, c} -> {:cont, c}
            {:error, _reason} -> {:halt, acc_conn}
          end
        end)
      end)

    conn
  end

  defp parse_filters(params) do
    %{
      action: blank_to_nil(params["action"]),
      resource_type: blank_to_nil(params["resource_type"]),
      resource_id: blank_to_nil(params["resource_id"]),
      # Back-compat with old `actor_email` URLs.
      actor: blank_to_nil(params["actor"] || params["actor_email"]),
      date_from: parse_datetime(params["from"], :start_of_day),
      date_to: parse_datetime(params["to"], :end_of_day),
      include_children: params["include_children"] in ["1", "true", true]
    }
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  # Accepts either an ISO 8601 datetime or a date (YYYY-MM-DD); a bare date
  # turns into the start-of-day or end-of-day in UTC depending on `bound`.
  defp parse_datetime(nil, _), do: nil
  defp parse_datetime("", _), do: nil

  defp parse_datetime(value, bound) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        dt

      _ ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date_to_bound(date, bound)
          _ -> nil
        end
    end
  end

  defp date_to_bound(date, :start_of_day), do: DateTime.new!(date, ~T[00:00:00])
  defp date_to_bound(date, :end_of_day), do: DateTime.new!(date, ~T[23:59:59])
end

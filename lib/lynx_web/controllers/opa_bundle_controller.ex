defmodule LynxWeb.OPABundleController do
  @moduledoc """
  Serves the OPA bundle (issue #38). OPA polls this endpoint with the
  bearer token configured at deploy time; we return the tarball assembled
  by `Lynx.Service.OPABundle` with an ETag so unchanged polls short-circuit.
  """

  use LynxWeb, :controller

  alias Lynx.Service.OPABundle

  def fetch(conn, _params) do
    {etag, body} = OPABundle.build()

    cond do
      not_modified?(conn, etag) ->
        conn
        |> put_resp_header("etag", etag)
        |> send_resp(:not_modified, "")

      true ->
        conn
        |> put_resp_header("etag", etag)
        |> put_resp_content_type("application/gzip")
        |> send_resp(:ok, body)
    end
  end

  defp not_modified?(conn, etag) do
    case Plug.Conn.get_req_header(conn, "if-none-match") do
      [presented] -> presented == etag
      _ -> false
    end
  end
end

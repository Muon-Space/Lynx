# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.ReadyController do
  use LynxWeb, :controller

  def ready(conn, _params) do
    case Ecto.Adapters.SQL.query(Lynx.Repo, "SELECT 1") do
      {:ok, _} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(:ok, Jason.encode!(%{status: "ok"}))

      {:error, _} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(:service_unavailable, Jason.encode!(%{status: "database unavailable"}))
    end
  end
end

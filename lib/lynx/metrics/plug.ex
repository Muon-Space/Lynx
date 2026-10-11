# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Metrics.Plug do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET", path_info: ["metrics"]} = conn, _opts) do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4")
    |> send_resp(200, Lynx.Metrics.scrape())
  end

  def call(conn, _opts), do: send_resp(conn, 404, "Not found")
end

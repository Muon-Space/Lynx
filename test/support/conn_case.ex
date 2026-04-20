# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use LynxWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import LynxWeb.ConnCase

      alias LynxWeb.Router.Helpers, as: Routes

      # The default endpoint for testing
      @endpoint LynxWeb.Endpoint
    end
  end

  setup tags do
    Lynx.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Installs the app and returns the admin user's API key for use in
  `x-api-key`-authenticated requests.
  """
  def install_admin_and_get_api_key(conn, attrs \\ %{}) do
    params =
      Map.merge(
        %{
          app_name: "Lynx",
          app_url: "https://lynx.com",
          app_email: "hello@lynx.com",
          admin_name: "John Doe",
          admin_email: "john@example.com",
          admin_password: "password123"
        },
        attrs
      )

    # `Phoenix.ConnTest.post/3` is a macro that uses `@endpoint`; from a
    # plain helper function we have to dispatch manually.
    Phoenix.ConnTest.dispatch(conn, LynxWeb.Endpoint, :post, "/action/install", params)
    user = Lynx.Context.UserContext.get_user_by_email(params.admin_email)
    user.api_key
  end

  @doc """
  Adds the `x-api-key` header for API authentication.
  """
  def with_api_key(conn, api_key) do
    Plug.Conn.put_req_header(conn, "x-api-key", api_key)
  end
end

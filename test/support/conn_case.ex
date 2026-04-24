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

    # The install action mints an api_key but discards the plaintext
    # (only the hash is stored). Rotate to a known value so the test
    # has a usable bearer.
    new_key = Lynx.Service.AuthService.get_uuid()
    {:ok, _} = Lynx.Context.UserContext.rotate_api_key(user.uuid, new_key)
    new_key
  end

  @doc """
  Adds the `x-api-key` header for API authentication.
  """
  def with_api_key(conn, api_key) do
    Plug.Conn.put_req_header(conn, "x-api-key", api_key)
  end

  @doc """
  Creates a regular (non-super) user with an API key. Useful for testing
  per-permission gates: the user is authenticated but has no project grants
  unless the test explicitly adds them.
  """
  def create_regular_user_with_api_key(opts \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      email: "regular-#{n}@example.com",
      name: "Regular User #{n}",
      password: "password123"
    }

    attrs = Map.merge(defaults, opts)
    app_key = Lynx.Service.Settings.get_config("app_key", "")
    api_key = Lynx.Service.AuthService.get_random_salt(20)

    {:ok, user} =
      Lynx.Context.UserContext.create_user(
        Lynx.Context.UserContext.new_user(%{
          # `"regular"` is the canonical non-super DB value — the API auth
          # middleware does `String.to_atom(user.role)` and downstream
          # `Lynx.Service.Permission` matches on `:regular`.
          email: attrs.email,
          name: attrs.name,
          password_hash: Lynx.Service.AuthService.hash_password(attrs.password, app_key),
          verified: true,
          last_seen: DateTime.utc_now() |> DateTime.truncate(:second),
          role: "regular",
          api_key: api_key
        })
      )

    {user, api_key}
  end
end

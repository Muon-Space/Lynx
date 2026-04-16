# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Middleware.SCIMAuthMiddleware do
  @moduledoc """
  SCIM Auth Middleware - validates Bearer token for SCIM endpoints
  """

  import Plug.Conn

  require Logger

  def init(_opts), do: nil

  @doc """
  Validate SCIM bearer token from Authorization header
  """
  def call(conn, _opts) do
    if not scim_enabled?() do
      conn
      |> put_status(:not_found)
      |> Phoenix.Controller.json(%{
        "schemas" => ["urn:ietf:params:scim:api:messages:2.0:Error"],
        "status" => "404",
        "detail" => "SCIM is not enabled"
      })
      |> halt()
    else
      case get_bearer_token(conn) do
        nil ->
          conn
          |> put_status(:unauthorized)
          |> Phoenix.Controller.json(%{
            "schemas" => ["urn:ietf:params:scim:api:messages:2.0:Error"],
            "status" => "401",
            "detail" => "Missing or invalid Authorization header"
          })
          |> halt()

        token ->
          expected = Application.get_env(:lynx, :scim_bearer_token)

          if expected != nil and Plug.Crypto.secure_compare(token, expected) do
            conn
            |> assign(:scim_authenticated, true)
          else
            Logger.info("SCIM auth failed: invalid bearer token")

            conn
            |> put_status(:unauthorized)
            |> Phoenix.Controller.json(%{
              "schemas" => ["urn:ietf:params:scim:api:messages:2.0:Error"],
              "status" => "401",
              "detail" => "Invalid bearer token"
            })
            |> halt()
          end
      end
    end
  end

  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end

  defp scim_enabled? do
    Application.get_env(:lynx, :scim_enabled, false)
  end
end

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.TaskController do
  @moduledoc """
  Task Controller
  """

  use LynxWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Lynx.Context.TaskContext
  alias LynxWeb.Schemas

  plug :regular_user when action in [:index]

  tags(["Tasks"])
  security([%{"api_key" => []}])

  operation(:index,
    summary: "Get a task by UUID",
    parameters: [
      uuid: [in: :path, required: true, type: :string]
    ],
    responses: [
      ok: {"Task", "application/json", Schemas.Task},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  defp regular_user(conn, _opts) do
    Logger.info("Validate user permissions")

    if not conn.assigns[:is_logged] do
      Logger.info("User doesn't have the right access permissions")

      conn
      |> put_status(:forbidden)
      |> render(:error, %{message: "Forbidden Access"})
      |> halt
    else
      Logger.info("User has the right access permissions")

      conn
    end
  end

  @doc """
  Index Action Endpoint
  """
  def index(conn, %{"uuid" => uuid}) do
    case TaskContext.fetch_task_by_uuid(uuid) do
      {:not_found, msg} ->
        conn
        |> put_status(:not_found)
        |> render(:error, %{message: msg})

      {:ok, task} ->
        conn
        |> put_status(:ok)
        |> render(:index, %{task: task})
    end
  end
end

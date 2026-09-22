# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.LockJSON do
  @moduledoc """
  JSON for the Terraform http-backend lock protocol. PascalCase keys and
  the field set mirror terraform's `statemgr.LockInfo`.

  Terraform decodes a 423/409 body into that struct, and `Created` is a Go
  `time.Time`, which only accepts RFC 3339. A naive timestamp such as
  `2026-09-22T15:55:54` fails to decode, terraform then treats the
  LockError as malformed and gives up instead of retrying under
  `-lock-timeout`. So `Created` is always rendered in UTC with a `Z`.
  """

  def render("lock_data.json", %{lock: lock}) do
    %{
      ID: lock.uuid,
      Path: lock.path || "",
      Operation: lock.operation || "",
      Who: lock.who || "",
      Version: lock.version || "",
      Created: rfc3339(lock.updated_at),
      Info: lock.info || ""
    }
  end

  def render("lock.json", %{}) do
    %{locked: true}
  end

  def render("unlock.json", %{}) do
    %{unlocked: true}
  end

  def render("error.json", %{message: msg}) do
    %{message: msg}
  end

  defp rfc3339(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp rfc3339(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> rfc3339()

  defp rfc3339(nil), do: DateTime.utc_now() |> rfc3339()
end

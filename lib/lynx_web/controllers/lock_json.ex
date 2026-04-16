# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.LockJSON do
  def render("lock_data.json", %{lock: lock}) do
    %{
      ID: lock.uuid,
      Path: lock.path,
      Operation: lock.operation,
      Who: lock.who,
      Version: lock.version,
      Created: lock.updated_at,
      Info: lock.info
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
end

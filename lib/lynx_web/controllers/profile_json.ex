# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.ProfileJSON do
  def render("success.json", %{message: message}) do
    %{successMessage: message}
  end

  def render("error.json", %{message: message}) do
    %{errorMessage: message}
  end

  def render("user.json", %{api_key: api_key, api_key_prefix: prefix}) do
    %{apiKey: api_key, apiKeyPrefix: prefix}
  end
end

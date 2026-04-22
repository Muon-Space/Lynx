defmodule Lynx.Context.RoleContextDescriptionsTest do
  @moduledoc """
  `RoleContext.permission_description/1` — every canonical permission has a
  non-empty description so the `/admin/roles` checkbox grid never has to
  fall back to a bare permission string.
  """
  use ExUnit.Case, async: true

  alias Lynx.Context.RoleContext

  test "every permission has a non-empty description" do
    for perm <- RoleContext.permissions() do
      desc = RoleContext.permission_description(perm)
      assert is_binary(desc) and desc != "", "permission #{inspect(perm)} has no description"
    end
  end

  test "force_unlock + unlock descriptions clarify the difference" do
    unlock = RoleContext.permission_description("state:unlock")
    force = RoleContext.permission_description("state:force_unlock")

    # The whole point of the split: callers should be able to distinguish
    # these two permissions from their descriptions alone.
    assert unlock != force
    assert force =~ ~r/(force|destructive|admin|another)/i
  end

  test "unknown permissions return empty string (no crash)" do
    assert RoleContext.permission_description("not:a:perm") == ""
  end
end

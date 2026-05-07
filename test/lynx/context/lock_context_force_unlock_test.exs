defmodule Lynx.Context.LockContextForceUnlockTest do
  @moduledoc """
  `force_unlock/1` cascades — clears the env-wide lock AND every active
  unit (sub_path) lock for the same environment. Earlier behavior cleared
  one row picked arbitrarily by the DB, so the env page often still
  reported "locked" after the admin clicked force-unlock.
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.LockContext

  setup do
    mark_installed()
    :ok
  end

  test "cascades: clears env-wide lock + every per-unit lock in one call" do
    project = create_project()
    env = create_env(project)

    create_lock(env, %{sub_path: ""})
    create_lock(env, %{sub_path: "groups", uuid: Ecto.UUID.generate()})
    create_lock(env, %{sub_path: "dns", uuid: Ecto.UUID.generate()})

    assert LockContext.is_environment_locked(env.id)

    assert {:success, msg} = LockContext.force_unlock(env.id)
    assert msg =~ "3 locks cleared"

    refute LockContext.is_environment_locked(env.id)
    assert LockContext.get_active_lock_by_environment_and_path(env.id, "") == nil
    assert LockContext.get_active_lock_by_environment_and_path(env.id, "groups") == nil
    assert LockContext.get_active_lock_by_environment_and_path(env.id, "dns") == nil
  end

  test "single env-wide lock returns the legacy message (no count suffix)" do
    project = create_project()
    env = create_env(project)
    create_lock(env, %{sub_path: ""})

    assert {:success, "Environment unlocked"} = LockContext.force_unlock(env.id)
    refute LockContext.is_environment_locked(env.id)
  end

  test "no active locks returns the no-op message without raising" do
    project = create_project()
    env = create_env(project)

    assert {:success, "Environment was not locked"} = LockContext.force_unlock(env.id)
  end

  test "only unit locks present (no env-wide lock) — earlier code did nothing" do
    project = create_project()
    env = create_env(project)

    create_lock(env, %{sub_path: "groups", uuid: Ecto.UUID.generate()})
    create_lock(env, %{sub_path: "dns", uuid: Ecto.UUID.generate()})

    assert LockContext.is_environment_locked(env.id)

    assert {:success, msg} = LockContext.force_unlock(env.id)
    assert msg =~ "2 locks cleared"

    refute LockContext.is_environment_locked(env.id)
  end
end

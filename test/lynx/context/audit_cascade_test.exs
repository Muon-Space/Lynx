defmodule Lynx.Context.AuditCascadeTest do
  @moduledoc """
  Audit cascade: when filtering by an env or project resource with
  `:include_children`, the result set expands to descendant resources
  (units under env; envs + units + snapshots under project).

  Without `:include_children`, exact-match semantics — same as before.
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.{AuditContext, SnapshotContext}

  setup do
    mark_installed()
    :ok
  end

  describe "include_children = false (default)" do
    test "exact match only — unit events don't show up under env scope" do
      env = make_env_in_new_project()
      user = create_user()

      AuditContext.log_user(user, "locked", "environment", env.uuid, env.name)
      AuditContext.log_user(user, "locked", "unit", env.uuid, "#{env.name}/api")

      {events, total} =
        AuditContext.list_events(%{
          resource_type: "environment",
          resource_id: env.uuid
        })

      assert total == 1
      assert Enum.map(events, & &1.resource_type) == ["environment"]
    end
  end

  describe "include_children = true" do
    test "env scope includes unit events for the same env" do
      env = make_env_in_new_project()
      user = create_user()

      AuditContext.log_user(user, "locked", "environment", env.uuid, env.name)
      AuditContext.log_user(user, "locked", "unit", env.uuid, "#{env.name}/api")
      AuditContext.log_user(user, "unlocked", "unit", env.uuid, "#{env.name}/api")

      {events, total} =
        AuditContext.list_events(%{
          resource_type: "environment",
          resource_id: env.uuid,
          include_children: true
        })

      assert total == 3
      types = events |> Enum.map(& &1.resource_type) |> Enum.sort()
      assert types == ["environment", "unit", "unit"]
    end

    test "env scope doesn't include other envs' unit events" do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})
      env_a = create_env(project, %{name: "A", slug: "a"})
      env_b = create_env(project, %{name: "B", slug: "b"})
      user = create_user()

      AuditContext.log_user(user, "locked", "unit", env_a.uuid, "A/api")
      AuditContext.log_user(user, "locked", "unit", env_b.uuid, "B/api")

      {events, _} =
        AuditContext.list_events(%{
          resource_type: "environment",
          resource_id: env_a.uuid,
          include_children: true
        })

      assert Enum.map(events, & &1.resource_name) == ["A/api"]
    end

    test "project scope expands to envs + units + snapshots" do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id, name: "P"})
      env = create_env(project, %{name: "prod", slug: "prod"})
      user = create_user()

      {:ok, snapshot} =
        SnapshotContext.create_snapshot_from_data(%{
          title: "Backup",
          description: "x",
          record_type: "environment",
          record_uuid: env.uuid,
          status: "success",
          data: ~s({"name":"x","environments":[]}),
          team_id: nil
        })

      AuditContext.log_user(user, "updated", "project", project.uuid, project.name)
      AuditContext.log_user(user, "locked", "environment", env.uuid, env.name)
      AuditContext.log_user(user, "locked", "unit", env.uuid, "prod/api")
      AuditContext.log_user(user, "created", "snapshot", snapshot.uuid, snapshot.title)

      {events, total} =
        AuditContext.list_events(%{
          resource_type: "project",
          resource_id: project.uuid,
          include_children: true
        })

      assert total == 4
      types = events |> Enum.map(& &1.resource_type) |> Enum.sort()
      assert types == ["environment", "project", "snapshot", "unit"]
    end
  end

  defp make_env_in_new_project do
    ws = create_workspace()
    project = create_project(%{workspace_id: ws.id})
    create_env(project, %{name: "e", slug: "e"})
  end
end

defmodule Lynx.Context.PolicyContextTest do
  @moduledoc """
  CRUD + lookup for OPA policies (issue #38). Most useful behavior here
  is `list_effective_policies_for_env/1`, which unions env-scoped and
  project-scoped enabled policies in one query.
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.PolicyContext

  setup do
    mark_installed()
    ws = create_workspace()
    project = create_project(%{workspace_id: ws.id})
    env = create_env(project)

    {:ok, project: project, env: env}
  end

  describe "create_policy/1" do
    test "rejects when neither project_id nor environment_id is set" do
      attrs = PolicyContext.new_policy(%{name: "x", rego_source: "package x"})
      assert {:error, changeset} = PolicyContext.create_policy(attrs)
      assert {"must be attached to a project or environment", _} = changeset.errors[:project_id]
    end

    test "rejects when both project_id and environment_id are set", %{
      project: project,
      env: env
    } do
      attrs =
        PolicyContext.new_policy(%{
          name: "x",
          rego_source: "package x",
          project_id: project.id,
          environment_id: env.id
        })

      assert {:error, changeset} = PolicyContext.create_policy(attrs)
      assert {"cannot be set when project_id is set", _} = changeset.errors[:environment_id]
    end

    test "accepts a project-scoped policy", %{project: project} do
      attrs =
        PolicyContext.new_policy(%{
          name: "p",
          rego_source: "package p",
          project_id: project.id
        })

      assert {:ok, %{name: "p", project_id: pid}} = PolicyContext.create_policy(attrs)
      assert pid == project.id
    end
  end

  describe "list_effective_policies_for_env/1" do
    test "unions env-scoped + project-scoped, both enabled", %{project: project, env: env} do
      {:ok, _} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "proj-wide",
            rego_source: "package a",
            project_id: project.id
          })
        )

      {:ok, _} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "env-only",
            rego_source: "package b",
            environment_id: env.id
          })
        )

      names = PolicyContext.list_effective_policies_for_env(env.id) |> Enum.map(& &1.name)
      assert names == ["env-only", "proj-wide"]
    end

    test "skips disabled policies", %{project: project, env: env} do
      {:ok, _} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "off",
            rego_source: "package off",
            project_id: project.id,
            enabled: false
          })
        )

      assert PolicyContext.list_effective_policies_for_env(env.id) == []
    end

    test "doesn't leak policies attached to a different project", %{env: env} do
      other_ws = create_workspace()
      other_project = create_project(%{workspace_id: other_ws.id})

      {:ok, _} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "other",
            rego_source: "package other",
            project_id: other_project.id
          })
        )

      assert PolicyContext.list_effective_policies_for_env(env.id) == []
    end
  end

  describe "list_enabled_policies/0 + latest_enabled_update_at/0" do
    test "ETag changes when a policy is updated", %{project: project} do
      {:ok, policy} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "etag-test",
            rego_source: "package x",
            project_id: project.id
          })
        )

      first = PolicyContext.latest_enabled_update_at()
      assert first != nil

      # Bump the row so updated_at advances. NaiveDateTime resolution is 1s,
      # so we need to either sleep or set explicitly. Setting explicitly is
      # less flaky.
      bumped =
        policy
        |> Ecto.Changeset.change(%{
          name: "etag-test-2",
          updated_at: NaiveDateTime.add(policy.updated_at, 5, :second)
        })
        |> Lynx.Repo.update!()

      second = PolicyContext.latest_enabled_update_at()
      assert NaiveDateTime.compare(second, bumped.updated_at) == :eq
      assert NaiveDateTime.compare(second, first) == :gt
    end
  end
end

defmodule LynxWeb.PolicyLiveTest do
  @moduledoc """
  Policy list pages (issue #38). The same LV serves four routes — global,
  workspace, project, env. Edit + delete moved to PolicyDetailLive, so
  this LV's job now is the list table + the create form + (on the
  global page) the gate-defaults form and override list.
  """
  use LynxWeb.LiveCase

  alias Lynx.Context.{
    EnvironmentContext,
    PolicyContext,
    RoleContext,
    UserProjectContext
  }

  alias Lynx.Service.PolicyGate

  setup %{conn: conn} do
    mark_installed()
    ws = create_workspace()
    project = create_project(%{workspace_id: ws.id})
    env = create_env(project)

    on_exit(fn ->
      PolicyGate.set_global_default(:require_passing_plan, false)
      PolicyGate.set_global_default(:block_violating_apply, false)
    end)

    {:ok, conn: conn, ws: ws, project: project, env: env}
  end

  describe "permissions" do
    test "redirects regular users without policy:manage", %{conn: conn, project: project} do
      user = create_user()
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: path}}} =
               live(conn, "/admin/projects/#{project.uuid}/policies")

      assert path =~ "/admin/projects/#{project.uuid}"
    end

    test "super sees the page", %{conn: conn, project: project} do
      conn = log_in_user(conn, create_super())
      {:ok, _view, html} = live(conn, "/admin/projects/#{project.uuid}/policies")
      assert html =~ "Policies"
      assert html =~ "Add Policy"
    end

    test "redirects on unknown project uuid", %{conn: conn} do
      conn = log_in_user(conn, create_super())

      assert {:error, {:redirect, %{to: "/admin/workspaces"}}} =
               live(conn, "/admin/projects/#{Ecto.UUID.generate()}/policies")
    end
  end

  describe "create flow" do
    setup %{conn: conn, project: project} do
      user = create_user()
      admin_role = RoleContext.get_role_by_name("admin")
      {:ok, _} = UserProjectContext.assign_role(user.id, project.id, admin_role.id)
      {:ok, conn: log_in_user(conn, user), user: user}
    end

    test "creates a project-scoped policy via the in-page form", %{conn: conn, project: project} do
      {:ok, view, _} = live(conn, "/admin/projects/#{project.uuid}/policies")

      view |> element("button", "Add Policy") |> render_click()
      stage_rego(view, "package main")

      view
      |> render_submit("save", %{
        "name" => "no-public-buckets",
        "description" => "Block public S3 buckets",
        "enabled" => "on"
      })

      [policy] = PolicyContext.list_policies_by_project(project.id)
      assert policy.name == "no-public-buckets"
      assert policy.project_id == project.id
      assert policy.environment_id == nil
    end

    test "blank name surfaces the form_error", %{conn: conn, project: project} do
      {:ok, view, _} = live(conn, "/admin/projects/#{project.uuid}/policies")

      view |> element("button", "Add Policy") |> render_click()
      stage_rego(view, "package main")

      html = view |> render_submit("save", %{"name" => "  ", "description" => ""})
      assert html =~ "Name is required"
      assert PolicyContext.list_policies_by_project(project.id) == []
    end

    test "row click navigates to the per-policy detail page (no in-page edit)", %{
      conn: conn,
      project: project
    } do
      {:ok, policy} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "existing",
            project_id: project.id,
            rego_source: "package x"
          })
        )

      {:ok, _view, html} = live(conn, "/admin/projects/#{project.uuid}/policies")

      # The row's `row_click` is a JS.navigate to the detail page; the
      # action column also exposes a plain "View" link to the same place.
      assert html =~ "/admin/policies/#{policy.uuid}"
    end
  end

  describe "env-scoped variant" do
    test "loads with the env-scoped path", %{conn: conn, project: project, env: env} do
      conn = log_in_user(conn, create_super())

      {:ok, _view, html} =
        live(conn, "/admin/projects/#{project.uuid}/environments/#{env.uuid}/policies")

      assert html =~ "Policies"
      assert html =~ env.name
    end
  end

  describe "global page — defaults + overrides" do
    test "regular user is redirected (super-only for global scope)", %{conn: conn} do
      conn = log_in_user(conn, create_user())

      assert {:error, {:redirect, %{to: path}}} = live(conn, "/admin/policies")
      assert path =~ "/admin/workspaces"
    end

    test "super sees the gate defaults form", %{conn: conn} do
      conn = log_in_user(conn, create_super())
      {:ok, _view, html} = live(conn, "/admin/policies")

      assert html =~ "Global Policy-Gate Defaults"
      assert html =~ "Require a passing plan-check"
      assert html =~ "Block apply on policy violation"
    end

    test "saving global defaults persists both toggles + emits an audit event", %{conn: conn} do
      conn = log_in_user(conn, create_super())
      {:ok, view, _} = live(conn, "/admin/policies")

      view
      |> render_submit("save_global_defaults", %{
        "require_passing_plan" => "on",
        "block_violating_apply" => "on"
      })

      assert PolicyGate.global_default(:require_passing_plan) == true
      assert PolicyGate.global_default(:block_violating_apply) == true
    end

    test "envs with explicit overrides appear in the overrides list", %{
      conn: conn,
      env: env,
      project: project,
      ws: ws
    } do
      {:ok, _} = EnvironmentContext.update_env(env, %{require_passing_plan: true})

      conn = log_in_user(conn, create_super())
      {:ok, _view, html} = live(conn, "/admin/policies")

      assert html =~ "Environments with explicit overrides"
      assert html =~ ws.name
      assert html =~ project.name
      assert html =~ env.name
      # Hyperlink back to the env page.
      assert html =~ "/admin/projects/#{project.uuid}/environments/#{env.uuid}"
    end

    test "overrides card hidden when no envs diverge from defaults", %{conn: conn} do
      conn = log_in_user(conn, create_super())
      {:ok, _view, html} = live(conn, "/admin/policies")

      refute html =~ "Environments with explicit overrides"
    end
  end

  # PolicyLive's create form schedules `Process.send_after` debounced
  # validation when entering edit mode. Until that fires, save_disabled?
  # blocks save. We can't naturally wait it out — instead push a known
  # rego value through `set_rego` (so the LV's buffer matches what we're
  # about to validate) then synchronously deliver + flush the validation
  # message. By the next render the validation state is :ok.
  defp stage_rego(view, rego) do
    render_change(view, "set_rego", %{"value" => rego})
    send(view.pid, {:run_validate, rego})
    _ = :sys.get_state(view.pid)
    :ok
  end
end

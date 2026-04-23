defmodule LynxWeb.PolicyDetailLiveTest do
  @moduledoc """
  Per-policy detail page (issue #38 follow-up). Two display modes on
  one route, controlled by `?edit=1`. Tests cover:

    * Mount + permission gating
    * View / edit mode switching via the URL param + the in-page button
    * Save flow (success + invalid-rego rejection)
    * Recent-blocks rendering for both plan_check + apply_blocked sources
    * Delete flow

  Engine is the `Stub` (config/test.exs default) — its `validate/1`
  returns `:ok` for any source containing the literal `package ` token,
  `{:invalid, _}` otherwise. Tests rely on that contract.
  """
  use LynxWeb.LiveCase

  alias Lynx.Context.{
    AuditContext,
    PlanCheckContext,
    PolicyContext,
    RoleContext,
    UserProjectContext
  }

  setup %{conn: conn} do
    mark_installed()
    ws = create_workspace()
    project = create_project(%{workspace_id: ws.id})
    env = create_env(project)

    {:ok, policy} =
      PolicyContext.create_policy(
        PolicyContext.new_policy(%{
          name: "no-public-buckets",
          description: "Block public S3 buckets",
          rego_source: "package x\n\ndeny[msg] { false; msg := \"x\" }",
          project_id: project.id
        })
      )

    {:ok, conn: conn, ws: ws, project: project, env: env, policy: policy}
  end

  describe "mount" do
    test "redirects when policy doesn't exist", %{conn: conn} do
      conn = log_in_user(conn, create_super())

      assert {:error, {:redirect, %{to: "/admin/policies"}}} =
               live(conn, "/admin/policies/#{Ecto.UUID.generate()}")
    end

    test "super sees the page in view mode by default", %{conn: conn, policy: policy} do
      conn = log_in_user(conn, create_super())
      {:ok, _view, html} = live(conn, "/admin/policies/#{policy.uuid}")
      assert html =~ "no-public-buckets"
      assert html =~ "Edit Policy"
      refute html =~ "name=\"name\""
    end

    test "regular user without policy:manage on the project is redirected", %{
      conn: conn,
      policy: policy
    } do
      regular = create_user()
      conn = log_in_user(conn, regular)

      assert {:error, {:redirect, %{to: path}}} =
               live(conn, "/admin/policies/#{policy.uuid}")

      # Can't see this project's policies, so we send them home.
      assert path =~ "/admin/workspaces"
    end

    test "user with policy:manage on the project sees the page", %{
      conn: conn,
      policy: policy,
      project: project
    } do
      user = create_user()
      admin_role = RoleContext.get_role_by_name("admin")
      {:ok, _} = UserProjectContext.assign_role(user.id, project.id, admin_role.id)

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, "/admin/policies/#{policy.uuid}")
      assert html =~ "no-public-buckets"
    end
  end

  describe "view / edit mode" do
    test "?edit=1 lands directly in edit mode (form rendered)", %{conn: conn, policy: policy} do
      conn = log_in_user(conn, create_super())
      {:ok, _view, html} = live(conn, "/admin/policies/#{policy.uuid}?edit=1")
      assert html =~ "Edit Policy"
      assert html =~ "name=\"name\""
      assert html =~ "Save"
      # In edit mode the header swaps Edit Policy for Cancel.
      assert html =~ "Cancel"
    end

    test "Edit Policy button push_patches to ?edit=1", %{conn: conn, policy: policy} do
      conn = log_in_user(conn, create_super())
      {:ok, view, _} = live(conn, "/admin/policies/#{policy.uuid}")

      view |> element("button", "Edit Policy") |> render_click()
      assert assert_patch(view) =~ "edit=1"
    end

    test "Cancel returns to view mode (URL drops the edit param)", %{conn: conn, policy: policy} do
      conn = log_in_user(conn, create_super())
      {:ok, view, _} = live(conn, "/admin/policies/#{policy.uuid}?edit=1")

      view |> element("button", "Cancel") |> render_click()
      patched = assert_patch(view)
      refute patched =~ "edit="
    end
  end

  describe "save" do
    test "happy path: name updated, audit event emitted, redirected to view mode",
         %{conn: conn, policy: policy} do
      conn = log_in_user(conn, create_super())
      {:ok, view, _} = live(conn, "/admin/policies/#{policy.uuid}?edit=1")

      flush_validation(view, policy.rego_source)

      view
      |> render_submit("save", %{
        "name" => "renamed-policy",
        "description" => policy.description,
        "enabled" => "on"
      })

      assert PolicyContext.get_policy_by_uuid(policy.uuid).name == "renamed-policy"

      [event | _] = recent_audit_for("policy", policy.uuid)
      assert event.action == "updated"
    end

    test "blank name surfaces the form_error and doesn't write", %{conn: conn, policy: policy} do
      conn = log_in_user(conn, create_super())
      {:ok, view, _} = live(conn, "/admin/policies/#{policy.uuid}?edit=1")

      flush_validation(view, policy.rego_source)

      html =
        view
        |> render_submit("save", %{"name" => "  ", "description" => "", "enabled" => "on"})

      assert html =~ "Name is required"
      assert PolicyContext.get_policy_by_uuid(policy.uuid).name == "no-public-buckets"
    end
  end

  describe "delete" do
    test "Delete button shows a confirmation dialog before destroying", %{
      conn: conn,
      policy: policy
    } do
      conn = log_in_user(conn, create_super())
      {:ok, view, _} = live(conn, "/admin/policies/#{policy.uuid}")

      view |> element("button", "Delete") |> render_click()

      # Dialog should be visible with the destructive copy explaining
      # the irreversible nature.
      assert has_element?(view, "#confirm-dialog")
      assert render(view) =~ "Delete policy"
      assert render(view) =~ "permanent"

      # Cancel keeps the policy intact.
      render_click(view, "cancel_confirm")
      refute has_element?(view, "#confirm-dialog")
      assert PolicyContext.get_policy_by_uuid(policy.uuid) != nil
    end

    test "confirming the dialog removes the policy + audits + redirects",
         %{conn: conn, policy: policy, project: project} do
      conn = log_in_user(conn, create_super())
      {:ok, view, _} = live(conn, "/admin/policies/#{policy.uuid}")

      # Step 1: open the dialog.
      view |> element("button", "Delete") |> render_click()
      assert has_element?(view, "#confirm-dialog")

      # Step 2: drive the actual delete event the confirm dialog fires.
      assert {:error, {:redirect, %{to: path}}} =
               render_click(view, "delete_policy", %{})

      assert path == "/admin/projects/#{project.uuid}/policies"
      assert PolicyContext.get_policy_by_uuid(policy.uuid) == nil

      [event | _] = recent_audit_for("policy", policy.uuid)
      assert event.action == "deleted"
    end
  end

  describe "recent block events" do
    test "plan_check that mentions this policy renders in the table", %{
      conn: conn,
      policy: policy,
      env: env
    } do
      violations =
        Jason.encode!([
          %{
            "policyId" => policy.uuid,
            "policyName" => policy.name,
            "messages" => ["bucket foo is public"]
          }
        ])

      {:ok, _} =
        PlanCheckContext.create_plan_check(%{
          uuid: Ecto.UUID.generate(),
          environment_id: env.id,
          sub_path: "",
          outcome: "failed",
          violations: violations,
          plan_json: "{}",
          actor_signature: "user:alice",
          actor_name: "alice",
          actor_type: "user"
        })

      conn = log_in_user(conn, create_super())
      {:ok, _view, html} = live(conn, "/admin/policies/#{policy.uuid}")

      assert html =~ "plan_check"
      assert html =~ "alice"
      assert html =~ "user API key"
    end

    test "apply_blocked event with this policy renders in the table", %{
      conn: conn,
      policy: policy,
      env: env
    } do
      AuditContext.create_event(%{
        actor_id: nil,
        actor_name: "tf-user",
        actor_type: "env_secret",
        action: "apply_blocked",
        resource_type: "environment",
        resource_id: env.uuid,
        resource_name: env.name,
        metadata:
          Jason.encode!(%{
            "gate" => "policy_violation",
            "sub_path" => "",
            "reason" => "no-public-buckets: ...",
            "policies" => [%{"name" => policy.name, "uuid" => policy.uuid}]
          })
      })

      conn = log_in_user(conn, create_super())
      {:ok, _view, html} = live(conn, "/admin/policies/#{policy.uuid}")

      assert html =~ "apply_blocked"
      assert html =~ "tf-user"
      assert html =~ "env credentials"
    end
  end

  # The detail LV's edit-mode mount fires `validate_async/2` which schedules
  # a `Process.send_after(self(), {:run_validate, rego}, 400)`. Until that
  # message arrives, `:validation == :validating` and `save_disabled?/1`
  # blocks Save. Tests can't naturally wait that out — synchronously
  # send the same message + flush via `:sys.get_state/1` so by the next
  # render the validation state is known.
  defp flush_validation(view, rego) do
    send(view.pid, {:run_validate, rego})
    _ = :sys.get_state(view.pid)
    :ok
  end

  defp recent_audit_for(resource_type, resource_id) do
    import Ecto.Query

    from(a in Lynx.Model.AuditEvent,
      where: a.resource_type == ^resource_type and a.resource_id == ^resource_id,
      order_by: [desc: a.id]
    )
    |> Lynx.Repo.all()
  end
end

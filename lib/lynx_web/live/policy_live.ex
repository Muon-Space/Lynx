defmodule LynxWeb.PolicyLive do
  @moduledoc """
  Manage OPA Rego policies attached at one of four scopes (issue #38):

      /admin/policies                                                  — global
      /admin/workspaces/:workspace_uuid/policies                       — workspace
      /admin/projects/:project_uuid/policies                           — project
      /admin/projects/:project_uuid/environments/:env_uuid/policies    — environment

  Effective set evaluated for each plan-check is the union of all four,
  filtered to `enabled: true`. Global + workspace scopes require the
  super role (no per-project context to gate on); project + env scopes
  use `project:manage` / `env:manage`.

  UI features:
    * Breadcrumb to make the current scope discoverable.
    * Scope badge in the header reinforcing the same.
    * Monaco editor with custom Rego highlighting and a side panel
      listing the canonical `input.*` keys from `terraform show -json`.
    * Live validation against OPA via `PolicyEngine.validate/1` with
      Save disabled while invalid OR while OPA is unreachable. The
      backend mirrors the same fail-closed behaviour — bad rego or
      unreachable OPA blocks the insert/update.
    * Every CRUD mutation emits an `AuditContext` event with scope
      metadata.
  """
  use LynxWeb, :live_view

  alias Lynx.Context.{
    AuditContext,
    EnvironmentContext,
    PolicyContext,
    ProjectContext,
    RoleContext,
    WorkspaceContext
  }

  alias Lynx.Model.Policy
  alias Lynx.Service.{PolicyEngine, PolicyGate}

  @validate_debounce_ms 400

  @impl true
  def mount(params, _session, socket) do
    case load_scope(params) do
      {:ok, scope_assigns} ->
        if can_manage?(socket.assigns.current_user, scope_assigns) do
          {:ok,
           socket
           |> assign(scope_assigns)
           |> assign(:policies, list_policies(scope_assigns))
           |> assign(:show_form?, false)
           |> assign(:form_error, nil)
           |> assign(:rego_buffer, "")
           |> assign(:rego_initial, "")
           |> assign(:validation, :ok)
           |> assign(:validate_ref, nil)
           |> load_global_extras(scope_assigns)}
        else
          {:ok,
           socket
           |> put_flash(:error, "You don't have permission to manage policies here.")
           |> redirect(to: deny_path(scope_assigns))}
        end

      :not_found ->
        {:ok, socket |> put_flash(:error, "Not found.") |> redirect(to: ~p"/admin/workspaces")}
    end
  end

  defp load_scope(%{"project_uuid" => p_uuid, "env_uuid" => e_uuid}) do
    with project when not is_nil(project) <- ProjectContext.get_project_by_uuid(p_uuid),
         env when not is_nil(env) <-
           EnvironmentContext.get_env_by_uuid_project(project.id, e_uuid),
         workspace when not is_nil(workspace) <- workspace_for(project) do
      {:ok, %{scope: :env, workspace: workspace, project: project, env: env}}
    else
      _ -> :not_found
    end
  end

  defp load_scope(%{"project_uuid" => p_uuid}) do
    case ProjectContext.get_project_by_uuid(p_uuid) do
      nil ->
        :not_found

      project ->
        case workspace_for(project) do
          nil -> :not_found
          ws -> {:ok, %{scope: :project, workspace: ws, project: project, env: nil}}
        end
    end
  end

  defp load_scope(%{"workspace_uuid" => ws_uuid}) do
    case WorkspaceContext.get_workspace_by_uuid(ws_uuid) do
      nil -> :not_found
      ws -> {:ok, %{scope: :workspace, workspace: ws, project: nil, env: nil}}
    end
  end

  defp load_scope(_), do: {:ok, %{scope: :global, workspace: nil, project: nil, env: nil}}

  defp workspace_for(%{workspace_id: nil}), do: nil

  defp workspace_for(%{workspace_id: ws_id}),
    do: WorkspaceContext.get_workspace_by_id(ws_id)

  # Global + workspace scopes have no project context to gate on, so they
  # remain super-only. Project + env scopes use the dedicated `policy:manage`
  # permission — separated from `project:manage` / `env:manage` so a
  # compliance/security role can own policies without also inheriting the
  # ability to delete the project or rotate env credentials.
  defp can_manage?(user, %{scope: :global}), do: super?(user)
  defp can_manage?(user, %{scope: :workspace}), do: super?(user)

  defp can_manage?(user, %{scope: :project, project: project}),
    do: super?(user) or RoleContext.can?(user, project, "policy:manage")

  defp can_manage?(user, %{scope: :env, project: project}),
    do: super?(user) or RoleContext.can?(user, project, "policy:manage")

  defp super?(%{role: "super"}), do: true
  defp super?(_), do: false

  defp deny_path(%{scope: :global}), do: ~p"/admin/workspaces"
  defp deny_path(%{scope: :workspace, workspace: ws}), do: ~p"/admin/workspaces/#{ws.uuid}"
  defp deny_path(%{scope: :project, project: p}), do: ~p"/admin/projects/#{p.uuid}"

  defp deny_path(%{scope: :env, project: p, env: e}),
    do: ~p"/admin/projects/#{p.uuid}/environments/#{e.uuid}"

  defp list_policies(%{scope: :global}), do: PolicyContext.list_policies_global()

  defp list_policies(%{scope: :workspace, workspace: ws}),
    do: PolicyContext.list_policies_by_workspace(ws.id)

  defp list_policies(%{scope: :project, project: p}),
    do: PolicyContext.list_policies_by_project(p.id)

  defp list_policies(%{scope: :env, env: env}),
    do: PolicyContext.list_policies_by_environment(env.id)

  # Global page also shows the two global default toggles + the list of
  # envs that have explicit overrides. Loaded only for :global so other
  # scopes don't pay the query cost.
  defp load_global_extras(socket, %{scope: :global}) do
    socket
    |> assign(
      :gate_default_require_passing_plan,
      PolicyGate.global_default(:require_passing_plan)
    )
    |> assign(
      :gate_default_block_violating_apply,
      PolicyGate.global_default(:block_violating_apply)
    )
    |> assign(:env_overrides, EnvironmentContext.list_envs_with_gate_overrides())
  end

  defp load_global_extras(socket, _), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current_user={@current_user} active={nav_active(@scope)} />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header title={page_title(@scope)} subtitle={scope_subtitle(@scope)} />

      <%!-- Global page only: defaults + override list, before the editor card. --%>
      <%= if @scope == :global do %>
        <.card class="mb-6">
          <h3 class="text-lg font-semibold mb-3">Global Policy-Gate Defaults</h3>
          <p class="text-sm text-muted mb-4">
            Default enforcement applied to every environment that hasn't set an explicit override.
            Per-env overrides live on the env page (requires <code>env:manage</code>).
          </p>
          <form phx-submit="save_global_defaults" class="space-y-3">
            <.input
              name="require_passing_plan"
              type="checkbox"
              label="Require a passing plan-check before apply (advanced — requires CI integration)"
              checked={@gate_default_require_passing_plan}
              hint="Terraform doesn't call this endpoint automatically. CI must `curl POST /tf/.../plan` with the plan JSON before `terraform apply`. Use this when policies need to distinguish create / update / delete actions; otherwise prefer 'Block apply on policy violation' below — it works without integration."
            />
            <.input
              name="block_violating_apply"
              type="checkbox"
              label="Block apply on policy violation (no plan upload required)"
              checked={@gate_default_block_violating_apply}
              hint="Recommended default. Every state-write evaluates the new state body against effective policies. Any deny[msg] rejects the apply, even if no plan was uploaded. Works with stock terraform / terragrunt — no CI integration needed."
            />
            <.button type="submit" variant="primary" size="sm">Save Defaults</.button>
          </form>
        </.card>

        <.card :if={@env_overrides != []} class="mb-6">
          <h3 class="text-lg font-semibold mb-3">Environments with explicit overrides</h3>
          <p class="text-sm text-muted mb-4">
            Each row shows where the env diverges from the global defaults.
            Click through to manage the override.
          </p>
          <.table rows={@env_overrides} empty_message="No envs have explicit overrides.">
            <:col :let={row} label="Workspace">{row.workspace.name}</:col>
            <:col :let={row} label="Project">{row.project.name}</:col>
            <:col :let={row} label="Environment">
              <.link
                navigate={~p"/admin/projects/#{row.project.uuid}/environments/#{row.env.uuid}"}
                class="text-clickable hover:text-clickable-hover"
              >
                {row.env.name}
              </.link>
            </:col>
            <:col :let={row} label="Plan gate">
              {gate_override_label(row.env.require_passing_plan)}
            </:col>
            <:col :let={row} label="Block on violation">
              {gate_override_label(row.env.block_violating_apply)}
            </:col>
          </.table>
        </.card>
      <% end %>

      <%!-- Breadcrumb makes the current scope discoverable + offers a click target back. --%>
      <div class="mb-4 flex items-center justify-between">
        <nav class="flex items-center gap-2 text-sm text-secondary flex-wrap">
          <.link href="/admin/workspaces" class="hover:text-foreground">Workspaces</.link>
          <%= if @workspace do %>
            <span>/</span>
            <.link href={"/admin/workspaces/#{@workspace.uuid}"} class="hover:text-foreground">
              {@workspace.name}
            </.link>
          <% end %>
          <%= if @project do %>
            <span>/</span>
            <.link href={"/admin/projects/#{@project.uuid}"} class="hover:text-foreground">
              {@project.name}
            </.link>
          <% end %>
          <%= if @env do %>
            <span>/</span>
            <.link href={"/admin/projects/#{@project.uuid}/environments/#{@env.uuid}"} class="hover:text-foreground">
              {@env.name}
            </.link>
          <% end %>
          <span>/</span>
          <span class="text-foreground font-medium">Policies</span>
          <.badge color={scope_badge_color(@scope)} class="ml-2">
            {scope_label(@scope)}
          </.badge>
        </nav>
        <.button :if={!@show_form?} phx-click="new" variant="primary" size="sm">
          Add Policy
        </.button>
      </div>

      <.card :if={@show_form?} class="mb-6">
        <h3 class="text-lg font-semibold mb-4">New Policy</h3>

        <form phx-submit="save" phx-change="validate" class="space-y-4">
          <.input name="name" label="Name" value="" required />
          <.input name="description" label="Description" value="" />
          <.input name="enabled" type="checkbox" label="Enabled" checked={true} />

          <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
            <%!-- Editor (2/3) + input reference panel (1/3) --%>
            <div class="lg:col-span-2">
              <label class="block text-sm font-medium text-secondary mb-1">Rego source</label>
              <p class="text-xs text-muted mb-2">
                Define a <code>deny contains msg if</code> rule that emits violation strings (OPA 1.0+ syntax).
                The <code>package</code> line is rewritten to a Lynx-controlled namespace on save.
              </p>
              <LiveMonacoEditor.code_editor
                id="rego-editor"
                path="policy.rego"
                value={@rego_initial}
                change="set_rego"
                style="height: 360px; min-width: 100%;"
                opts={
                  Map.merge(LiveMonacoEditor.default_opts(), %{
                    "language" => "rego",
                    "automaticLayout" => true,
                    "fontSize" => 13,
                    "wordWrap" => "on"
                  })
                }
              />

              <%!-- Live validation banner --%>
              <div class="mt-2">
                <.validation_banner validation={@validation} />
              </div>
            </div>

            <div class="lg:col-span-1">
              <label class="block text-sm font-medium text-secondary mb-1">
                Available <code>input.*</code> keys
              </label>
              <p class="text-xs text-muted mb-2">
                Lynx passes the full <code>terraform show -json</code> output as <code>input</code>.
                Common access patterns:
              </p>
              <div class="bg-inset rounded-lg p-3 text-xs font-mono space-y-2">
                <div>
                  <div class="text-clickable">input.format_version</div>
                  <div class="text-muted">"1.2", etc.</div>
                </div>
                <div>
                  <div class="text-clickable">input.terraform_version</div>
                </div>
                <div>
                  <div class="text-clickable">input.variables</div>
                  <div class="text-muted">map keyed by var name</div>
                </div>
                <div>
                  <div class="text-clickable">input.resource_changes[]</div>
                  <div class="text-muted ml-2">.address, .mode, .type, .name</div>
                  <div class="text-muted ml-2">.change.actions[]   ("create" / "update" / "delete")</div>
                  <div class="text-muted ml-2">.change.before, .change.after</div>
                </div>
                <div>
                  <div class="text-clickable">input.planned_values.root_module</div>
                  <div class="text-muted">post-apply state preview</div>
                </div>
                <div>
                  <div class="text-clickable">input.configuration</div>
                  <div class="text-muted">parsed module config</div>
                </div>
              </div>
            </div>
          </div>

          <p :if={@form_error} class="text-sm text-flash-error-text">{@form_error}</p>

          <div class="flex gap-2">
            <.button type="submit" variant="primary" disabled={save_disabled?(@validation)}>
              Create
            </.button>
            <.button phx-click="cancel" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.card>

      <.card>
        <.table
          rows={@policies}
          empty_message={"No policies attached at the #{scope_label(@scope)} scope yet."}
          row_click={fn p -> JS.navigate(~p"/admin/policies/#{p.uuid}") end}
        >
          <:col :let={p} label="Name">
            <span class="font-medium text-clickable">{p.name}</span>
          </:col>
          <:col :let={p} label="Description">{policy_description(p)}</:col>
          <:col :let={p} label="Status">
            <.badge color={if p.enabled, do: "green", else: "gray"}>
              {if p.enabled, do: "Enabled", else: "Disabled"}
            </.badge>
          </:col>
          <:action :let={p}>
            <.link navigate={~p"/admin/policies/#{p.uuid}"} class="text-secondary hover:text-foreground text-xs px-3 py-1.5">
              View
            </.link>
          </:action>
        </.table>
      </.card>
    </div>
    """
  end

  # -- Render helpers --

  defp page_title(:global), do: "Global Policies"
  defp page_title(:workspace), do: "Workspace Policies"
  defp page_title(:project), do: "Project Policies"
  defp page_title(:env), do: "Environment Policies"

  defp scope_subtitle(:global),
    do: "Apply to every plan upload across every workspace."

  defp scope_subtitle(:workspace),
    do: "Apply to every plan upload in this workspace."

  defp scope_subtitle(:project),
    do: "Apply to every plan upload in this project."

  defp scope_subtitle(:env),
    do: "Apply to plan uploads in this environment only."

  defp scope_label(:global), do: "Global"
  defp scope_label(:workspace), do: "Workspace"
  defp scope_label(:project), do: "Project"
  defp scope_label(:env), do: "Environment"

  defp scope_badge_color(:global), do: "purple"
  defp scope_badge_color(:workspace), do: "blue"
  defp scope_badge_color(:project), do: "green"
  defp scope_badge_color(:env), do: "yellow"

  defp gate_override_label(nil), do: "(inherit)"
  defp gate_override_label(true), do: "ON"
  defp gate_override_label(false), do: "OFF"

  defp nav_active(:global), do: "policies"
  defp nav_active(_), do: ""

  defp policy_description(%{description: ""}), do: "—"
  defp policy_description(%{description: nil}), do: "—"
  defp policy_description(%{description: d}), do: d

  # Match the backend's strict fail-closed: invalid rego AND
  # OPA-unreachable both block save.
  defp save_disabled?({:invalid, _}), do: true
  defp save_disabled?({:warning, _}), do: true
  defp save_disabled?(:validating), do: true
  defp save_disabled?(_), do: false

  attr :validation, :any, required: true

  defp validation_banner(%{validation: :ok} = assigns) do
    ~H"""
    <span class="text-xs text-flash-success-text">Validated against OPA — no errors.</span>
    """
  end

  defp validation_banner(%{validation: {:invalid, errors}} = assigns) do
    assigns = assign(assigns, :errors, errors)

    ~H"""
    <div class="text-xs space-y-1">
      <p class="text-flash-error-text font-medium">Rego invalid — fix before saving:</p>
      <ul class="list-disc ml-5 text-flash-error-text">
        <li :for={e <- @errors}>
          <span :if={e[:row]}>line {e.row}{if e[:col], do: ":#{e.col}"}: </span>{e.message}
        </li>
      </ul>
    </div>
    """
  end

  defp validation_banner(%{validation: {:warning, msg}} = assigns) do
    assigns = assign(assigns, :msg, msg)

    ~H"""
    <span class="text-xs text-flash-error-text">
      {@msg} Save is disabled until OPA is reachable.
    </span>
    """
  end

  defp validation_banner(assigns) do
    ~H"""
    <span class="text-xs text-muted">Validating…</span>
    """
  end

  # -- Events --

  @impl true
  def handle_event("new", _, socket) do
    initial = default_rego()

    {:noreply,
     socket
     |> assign(:editing, nil)
     |> assign(:show_form?, true)
     |> assign(:rego_buffer, initial)
     |> assign(:rego_initial, initial)
     |> assign(:form_error, nil)
     |> validate_async(initial)}
  end

  def handle_event("cancel", _, socket) do
    {:noreply,
     socket
     |> assign(:show_form?, false)
     |> assign(:form_error, nil)
     |> assign(:validation, :ok)}
  end

  # The editor pushes its full value via the `change` callback. Debounce
  # the OPA call so we don't hammer it on every keystroke.
  def handle_event("set_rego", %{"value" => value}, socket) do
    {:noreply,
     socket
     |> assign(:rego_buffer, value)
     |> validate_async(value)}
  end

  def handle_event("validate", %{"_target" => ["live_monaco_editor", _]}, socket),
    do: {:noreply, socket}

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("save", params, socket) do
    rego = Map.get(socket.assigns, :rego_buffer, "") |> to_string()
    name = String.trim(params["name"] || "")
    description = String.trim(params["description"] || "")
    enabled = params["enabled"] in [true, "true", "on"]

    cond do
      name == "" ->
        {:noreply, assign(socket, :form_error, "Name is required.")}

      String.trim(rego) == "" ->
        {:noreply, assign(socket, :form_error, "Rego source is required.")}

      save_disabled?(socket.assigns.validation) ->
        {:noreply, assign(socket, :form_error, "Fix the rego validation errors before saving.")}

      true ->
        attrs = %{
          name: name,
          description: description,
          rego_source: rego,
          enabled: enabled
        }

        do_save(socket, attrs)
    end
  end

  def handle_event("save_global_defaults", params, socket) do
    require_plan = params["require_passing_plan"] in [true, "true", "on"]
    block_apply = params["block_violating_apply"] in [true, "true", "on"]

    PolicyGate.set_global_default(:require_passing_plan, require_plan)
    PolicyGate.set_global_default(:block_violating_apply, block_apply)

    AuditContext.log_user(
      socket.assigns.current_user,
      "updated",
      "policy_gate_defaults",
      nil,
      "global",
      Jason.encode!(%{
        "require_passing_plan" => require_plan,
        "block_violating_apply" => block_apply
      })
    )

    {:noreply,
     socket
     |> assign(:gate_default_require_passing_plan, require_plan)
     |> assign(:gate_default_block_violating_apply, block_apply)
     |> put_flash(:info, "Global policy-gate defaults saved.")}
  end

  def handle_event("confirm_delete", %{"uuid" => uuid}, socket) do
    case PolicyContext.get_policy_by_uuid(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, "Policy not found.")}

      policy ->
        case PolicyContext.delete_policy(policy) do
          {:ok, _} ->
            log_audit(socket, "deleted", policy)

            {:noreply,
             socket
             |> assign(:policies, list_policies(socket.assigns))
             |> put_flash(:info, "Policy deleted.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not delete policy.")}
        end
    end
  end

  defp do_save(socket, attrs) do
    # PolicyLive only handles the create flow now — edits live on
    # PolicyDetailLive. Always insert.
    result =
      attrs
      |> Map.merge(scope_columns(socket.assigns))
      |> PolicyContext.new_policy()
      |> PolicyContext.create_policy()

    case result do
      {:ok, policy} ->
        log_audit(socket, "created", policy)

        {:noreply,
         socket
         |> assign(:show_form?, false)
         |> assign(:form_error, nil)
         |> assign(:policies, list_policies(socket.assigns))
         |> put_flash(:info, "Policy created.")}

      {:error, changeset} ->
        msg =
          changeset.errors
          |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)
          |> Enum.join("; ")

        {:noreply, assign(socket, :form_error, msg)}
    end
  end

  defp scope_columns(%{scope: :global}),
    do: %{workspace_id: nil, project_id: nil, environment_id: nil}

  defp scope_columns(%{scope: :workspace, workspace: ws}),
    do: %{workspace_id: ws.id, project_id: nil, environment_id: nil}

  defp scope_columns(%{scope: :project, project: p}),
    do: %{workspace_id: nil, project_id: p.id, environment_id: nil}

  defp scope_columns(%{scope: :env, env: env}),
    do: %{workspace_id: nil, project_id: nil, environment_id: env.id}

  # -- Audit logging (issue #38 follow-up) --

  defp log_audit(socket, action, %Policy{} = policy) do
    # Stash UUIDs in metadata so the audit page can build a deep-link to
    # the right policies-management URL without an extra DB lookup.
    metadata =
      %{
        scope: Atom.to_string(Policy.scope(policy)),
        workspace_uuid: socket.assigns[:workspace] && socket.assigns.workspace.uuid,
        project_uuid: socket.assigns[:project] && socket.assigns.project.uuid,
        env_uuid: socket.assigns[:env] && socket.assigns.env.uuid
      }
      |> Jason.encode!()

    AuditContext.log_user(
      socket.assigns.current_user,
      action,
      "policy",
      policy.uuid,
      policy.name,
      metadata
    )
  end

  # -- Live validation against OPA --
  #
  # Cancels any in-flight debounce timer + schedules a new one. The
  # timer message arrives at the LV as `:run_validate`; until it does,
  # the UI shows "Validating…". Round-tripping to OPA per change is
  # cheap (~10ms locally) but the debounce keeps it sane during typing.

  defp validate_async(socket, rego) do
    if ref = socket.assigns[:validate_ref], do: Process.cancel_timer(ref)

    new_ref = Process.send_after(self(), {:run_validate, rego}, @validate_debounce_ms)

    socket
    |> assign(:validate_ref, new_ref)
    |> assign(:validation, :validating)
  end

  @impl true
  def handle_info({:run_validate, rego}, socket) do
    # Stale timer guard: if the buffer changed after this timer was set,
    # bail — a newer timer will fire with the current value.
    if rego == socket.assigns.rego_buffer do
      result =
        case PolicyEngine.validate(rego) do
          :ok ->
            :ok

          {:invalid, errors} ->
            {:invalid, errors}

          {:error, _} ->
            {:warning, "OPA is unreachable, can't validate this rego."}
        end

      {:noreply, assign(socket, :validation, result) |> assign(:validate_ref, nil)}
    else
      {:noreply, socket}
    end
  end

  defp default_rego do
    """
    package main

    # Emit a violation message per disallowed change. Lynx aggregates these
    # across all attached policies into the plan_check `outcome`.
    deny contains msg if {
      some i
      resource := input.resource_changes[i]
      resource.type == "aws_s3_bucket"
      resource.change.after.acl == "public-read"
      msg := sprintf("S3 bucket %s is publicly readable", [resource.address])
    }
    """
  end
end

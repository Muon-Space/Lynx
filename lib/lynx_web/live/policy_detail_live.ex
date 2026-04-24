defmodule LynxWeb.PolicyDetailLive do
  @moduledoc """
  Per-policy detail page (issue #38 follow-up).

  Mounted at `/admin/policies/:uuid`. Two display modes on the same
  route, controlled by `?edit=1`:

    * **View** (default) — read-only Monaco of the rego, breadcrumb,
      scope + status badges, and a recent-blocks table.
    * **Edit** — full form (name, description, enabled, rego editor)
      with live OPA validation + save-disabled-while-invalid. Saving
      lands you back in view mode; Cancel does the same without
      writing.

  Permission model mirrors `PolicyLive`:
    * Global / workspace scopes → super only
    * Project / env scopes → super OR `policy:manage` on that project
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
  alias Lynx.Service.PolicyEngine

  @validate_debounce_ms 400

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    case PolicyContext.get_policy_by_uuid(uuid) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Policy not found.")
         |> redirect(to: ~p"/admin/policies")}

      policy ->
        scope = Policy.scope(policy)
        scope_assigns = resolve_scope_context(policy, scope)
        can_view? = can_view?(socket.assigns.current_user, scope, scope_assigns)
        can_edit? = can_manage?(socket.assigns.current_user, scope, scope_assigns)

        if can_view? do
          {:ok,
           socket
           |> assign(:policy, policy)
           |> assign(:scope, scope)
           |> assign(scope_assigns)
           |> assign(:can_edit?, can_edit?)
           |> assign(:editing?, false)
           |> assign(:rego_buffer, policy.rego_source)
           |> assign(:rego_initial, policy.rego_source)
           |> assign(:validation, :ok)
           |> assign(:validate_ref, nil)
           |> assign(:form_error, nil)
           |> assign(:confirm, nil)
           |> assign(:recent_blocks, PolicyContext.recent_blocks_for_policy(policy, 25))}
        else
          {:ok,
           socket
           |> put_flash(:error, "You don't have permission to view this policy.")
           |> redirect(to: ~p"/admin/workspaces")}
        end
    end
  end

  # `?edit=1` opens edit mode (used by chips / external deep links).
  # No param keeps view mode. Toggling via the in-page button push_patches
  # this same param so the URL is shareable.
  @impl true
  def handle_params(params, _uri, socket) do
    edit_requested? = params["edit"] in ["1", "true"]

    cond do
      edit_requested? and socket.assigns.can_edit? ->
        {:noreply, enter_edit_mode(socket)}

      edit_requested? and not socket.assigns.can_edit? ->
        {:noreply, put_flash(socket, :error, "You don't have permission to edit this policy.")}

      true ->
        {:noreply, leave_edit_mode(socket)}
    end
  end

  defp enter_edit_mode(socket) do
    socket
    |> assign(:editing?, true)
    |> assign(:rego_buffer, socket.assigns.policy.rego_source)
    |> assign(:rego_initial, socket.assigns.policy.rego_source)
    |> assign(:form_error, nil)
    |> validate_async(socket.assigns.policy.rego_source)
  end

  defp leave_edit_mode(socket),
    do: assign(socket, :editing?, false) |> assign(:form_error, nil)

  defp resolve_scope_context(%Policy{environment_id: env_id}, :env) do
    env = EnvironmentContext.get_env_by_id(env_id)
    project = env && ProjectContext.get_project_by_id(env.project_id)
    workspace = project && WorkspaceContext.get_workspace_by_id(project.workspace_id)
    %{env: env, project: project, workspace: workspace}
  end

  defp resolve_scope_context(%Policy{project_id: id}, :project) do
    project = ProjectContext.get_project_by_id(id)
    workspace = project && WorkspaceContext.get_workspace_by_id(project.workspace_id)
    %{env: nil, project: project, workspace: workspace}
  end

  defp resolve_scope_context(%Policy{workspace_id: id}, :workspace) do
    %{env: nil, project: nil, workspace: WorkspaceContext.get_workspace_by_id(id)}
  end

  defp resolve_scope_context(_, :global), do: %{env: nil, project: nil, workspace: nil}

  # Visibility: super always; for project/env-scoped policies, anyone
  # who can manage policies on that project. global/workspace remain
  # super-only for visibility (mirrors PolicyLive's manage rules).
  defp can_view?(%{role: "super"}, _, _), do: true
  defp can_view?(_user, scope, _) when scope in [:global, :workspace], do: false

  defp can_view?(user, _scope, %{project: project}) when not is_nil(project),
    do: RoleContext.can?(user, project, "policy:manage")

  defp can_view?(_, _, _), do: false

  defp can_manage?(%{role: "super"}, _, _), do: true
  defp can_manage?(_user, scope, _) when scope in [:global, :workspace], do: false

  defp can_manage?(user, _scope, %{project: project}) when not is_nil(project),
    do: RoleContext.can?(user, project, "policy:manage")

  defp can_manage?(_, _, _), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <.confirm_dialog :if={@confirm} message={@confirm.message} confirm_event={@confirm.event} confirm_value={@confirm.value} />
    <.nav current_user={@current_user} active="" />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header
        title={@policy.name}
        subtitle={if @policy.description != "", do: @policy.description, else: scope_subtitle(@scope)}
      />

      <div class="mb-4 flex items-center justify-between flex-wrap gap-2">
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
          <.link href={scope_policies_path(@scope, @workspace, @project, @env)} class="hover:text-foreground">Policies</.link>
          <span>/</span>
          <span class="text-foreground font-medium">{@policy.name}</span>
          <.badge color={scope_badge_color(@scope)} class="ml-2">{scope_label(@scope)}</.badge>
          <.badge color={if @policy.enabled, do: "green", else: "gray"}>
            {if @policy.enabled, do: "Enabled", else: "Disabled"}
          </.badge>
        </nav>
        <%!-- Header action slot: Edit + Delete in view mode, Cancel
              in edit mode. Save lives inside the form (it needs to be a
              submit button) so we don't duplicate it here. Cancel taking
              over the Edit slot keeps the user's eye anchored on the
              same screen position when toggling. --%>
        <div class="flex items-center gap-2">
          <%= if @editing? do %>
            <.button phx-click="cancel_edit" variant="secondary" size="sm">Cancel</.button>
          <% else %>
            <.button
              :if={@can_edit?}
              phx-click="enter_edit"
              variant="primary"
              size="sm"
            >
              Edit Policy
            </.button>
            <.button
              :if={@can_edit?}
              phx-click="confirm_action"
              phx-value-event="delete_policy"
              phx-value-message={"Delete policy \"#{@policy.name}\"? This is permanent and any environment that depends on it will stop being evaluated."}
              variant="ghost"
              size="sm"
            >
              Delete
            </.button>
          <% end %>
        </div>
      </div>

      <%!-- View mode: read-only rego + input reference --%>
      <.card :if={not @editing?} class="mb-6">
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
          <div class="lg:col-span-2">
            <label class="block text-sm font-medium text-secondary mb-1">Rego source</label>
            <LiveMonacoEditor.code_editor
              id="rego-readonly"
              path="policy.rego"
              value={@policy.rego_source}
              style="height: 360px; min-width: 100%;"
              opts={
                Map.merge(LiveMonacoEditor.default_opts(), %{
                  "language" => "rego",
                  "automaticLayout" => true,
                  "fontSize" => 13,
                  "wordWrap" => "on",
                  "readOnly" => true
                })
              }
            />
          </div>
          <div class="lg:col-span-1">
            <.input_reference />
          </div>
        </div>
      </.card>

      <%!-- Edit mode: full form --%>
      <.card :if={@editing?} class="mb-6">
        <h3 class="text-lg font-semibold mb-4">Edit Policy</h3>
        <form phx-submit="save" phx-change="validate" class="space-y-4">
          <.input name="name" label="Name" value={@policy.name} required />
          <.input name="description" label="Description" value={@policy.description} />
          <.input name="enabled" type="checkbox" label="Enabled" checked={@policy.enabled} />

          <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
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
              <div class="mt-2">
                <.validation_banner validation={@validation} />
              </div>
            </div>
            <div class="lg:col-span-1">
              <.input_reference />
            </div>
          </div>

          <p :if={@form_error} class="text-sm text-flash-error-text">{@form_error}</p>

          <%!-- Save submits the form. Cancel lives in the header
                action slot (replacing Edit Policy) so toggling between
                view + edit doesn't shift the user's eye. --%>
          <.button type="submit" variant="primary" disabled={save_disabled?(@validation)}>
            Save
          </.button>
        </form>
      </.card>

      <.card>
        <h3 class="text-sm font-semibold text-secondary mb-3">
          Recent block events involving this policy
        </h3>
        <.table rows={@recent_blocks} empty_message="This policy hasn't fired any blocks recently.">
          <:col :let={r} label="When">
            <span class="text-xs text-muted">{Calendar.strftime(r.when, "%Y-%m-%d %H:%M:%S")}</span>
          </:col>
          <:col :let={r} label="Kind">
            <.badge color={if r.kind == "apply_blocked", do: "red", else: "yellow"}>
              {r.kind}
            </.badge>
          </:col>
          <:col :let={r} label="Environment">
            <%= if r.env && r.project do %>
              <.link
                navigate={~p"/admin/projects/#{r.project.uuid}/environments/#{r.env.uuid}"}
                class="text-clickable hover:text-clickable-hover"
              >
                {r.workspace.name} › {r.project.name} › {r.env.name}
              </.link>
            <% else %>
              <span class="text-muted">—</span>
            <% end %>
          </:col>
          <:col :let={r} label="Sub-path">
            <code class="text-xs">{format_sub_path(r)}</code>
          </:col>
          <:col :let={r} label="Actor">
            <span class="text-xs">{r.actor_name || "—"} <span class="text-muted" title={actor_type_tooltip(r.actor_type)}>({actor_type_label(r.actor_type)})</span></span>
          </:col>
          <:col :let={r} label="Messages">
            <details>
              <summary class="text-muted cursor-pointer hover:text-foreground text-xs">
                {messages_summary(r)}
              </summary>
              <ul class="bg-inset rounded p-2 mt-1 list-disc ml-5 text-xs space-y-0.5">
                <li :for={msg <- messages_for(r)}>{msg}</li>
              </ul>
            </details>
          </:col>
        </.table>
      </.card>
    </div>
    """
  end

  # -- Sub-components --

  defp input_reference(assigns) do
    ~H"""
    <label class="block text-sm font-medium text-secondary mb-1">
      Available <code>input.*</code> keys
    </label>
    <div class="bg-inset rounded-lg p-3 text-xs font-mono space-y-2">
      <div>
        <div class="text-clickable">input.resource_changes[]</div>
        <div class="text-muted ml-2">.address, .mode, .type, .name</div>
        <div class="text-muted ml-2">.change.actions[]   ("create" / "update" / "delete")</div>
        <div class="text-muted ml-2">.change.before, .change.after</div>
        <div class="text-muted ml-2 italic">
          Note: at apply-block time, only the after-state is known —
          every change is tagged <code>actions: ["update"]</code>. Filter on
          <code>change.after.*</code> for rules that should fire on both gates.
        </div>
      </div>
      <div>
        <div class="text-clickable">input.planned_values.root_module</div>
        <div class="text-muted">post-apply state preview</div>
      </div>
      <div>
        <div class="text-clickable">input.configuration</div>
      </div>
    </div>
    """
  end

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

  # -- Render helpers --

  defp scope_label(:global), do: "Global"
  defp scope_label(:workspace), do: "Workspace"
  defp scope_label(:project), do: "Project"
  defp scope_label(:env), do: "Environment"

  defp scope_badge_color(:global), do: "purple"
  defp scope_badge_color(:workspace), do: "blue"
  defp scope_badge_color(:project), do: "green"
  defp scope_badge_color(:env), do: "yellow"

  defp scope_subtitle(:global), do: "Applies to every plan upload across every workspace."
  defp scope_subtitle(:workspace), do: "Applies to every plan upload in this workspace."
  defp scope_subtitle(:project), do: "Applies to every plan upload in this project."
  defp scope_subtitle(:env), do: "Applies to plan uploads in this environment only."

  defp scope_policies_path(:global, _, _, _), do: "/admin/policies"
  defp scope_policies_path(:workspace, ws, _, _), do: "/admin/workspaces/#{ws.uuid}/policies"
  defp scope_policies_path(:project, _, p, _), do: "/admin/projects/#{p.uuid}/policies"

  defp scope_policies_path(:env, _, p, e),
    do: "/admin/projects/#{p.uuid}/environments/#{e.uuid}/policies"

  defp save_disabled?({:invalid, _}), do: true
  defp save_disabled?({:warning, _}), do: true
  defp save_disabled?(:validating), do: true
  defp save_disabled?(_), do: false

  defp format_sub_path(%{kind: "plan_check", sub_path: ""}), do: "(root)"
  defp format_sub_path(%{kind: "plan_check", sub_path: sp}), do: sp

  defp format_sub_path(%{kind: "apply_blocked", metadata: meta}) when is_binary(meta) do
    case Jason.decode(meta) do
      {:ok, %{"sub_path" => "" <> _ = sp}} when sp != "" -> sp
      _ -> "(root)"
    end
  end

  defp format_sub_path(_), do: "(root)"

  defp messages_for(%{kind: "plan_check", violations: violations}) when is_binary(violations) do
    case Jason.decode(violations) do
      {:ok, list} when is_list(list) ->
        Enum.flat_map(list, fn v -> List.wrap(v["messages"]) end)

      _ ->
        []
    end
  end

  defp messages_for(%{kind: "apply_blocked", metadata: meta}) when is_binary(meta) do
    case Jason.decode(meta) do
      {:ok, %{"reason" => reason}} when is_binary(reason) -> [reason]
      _ -> []
    end
  end

  defp messages_for(_), do: []

  defp messages_summary(r) do
    case messages_for(r) do
      [] ->
        "(no message)"

      [single] ->
        String.slice(single, 0, 100) <> if(String.length(single) > 100, do: "…", else: "")

      list ->
        "#{length(list)} message(s)"
    end
  end

  # Translate the internal actor_type values (set by the /tf/ auth
  # pipeline) into human-readable labels with explanatory tooltips.
  # The internal strings (env_secret / oidc / user) are jargon; this
  # keeps the UI scannable while preserving the diagnostic value.
  defp actor_type_label("env_secret"), do: "env credentials"
  defp actor_type_label("oidc"), do: "OIDC token"
  defp actor_type_label("user"), do: "user API key"
  defp actor_type_label("system"), do: "system"
  defp actor_type_label(other), do: to_string(other)

  defp actor_type_tooltip("env_secret"),
    do: "Authenticated with the env's static username + secret (legacy / break-glass)."

  defp actor_type_tooltip("oidc"),
    do: "Authenticated with an OIDC JWT (typical CI flow)."

  defp actor_type_tooltip("user"),
    do: "Authenticated with a user's API key (typical local-dev flow)."

  defp actor_type_tooltip("system"), do: "Internal Lynx process."
  defp actor_type_tooltip(_), do: nil

  # -- Events --

  @impl true
  def handle_event("enter_edit", _, socket) do
    if socket.assigns.can_edit? do
      {:noreply, push_patch(socket, to: ~p"/admin/policies/#{socket.assigns.policy.uuid}?edit=1")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/policies/#{socket.assigns.policy.uuid}")}
  end

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
    if not socket.assigns.can_edit? do
      {:noreply, put_flash(socket, :error, "You don't have permission to edit this policy.")}
    else
      do_save(socket, params)
    end
  end

  def handle_event("confirm_action", params, socket) do
    {:noreply,
     assign(socket, :confirm, %{
       message: params["message"],
       event: params["event"],
       value: %{}
     })}
  end

  def handle_event("cancel_confirm", _, socket), do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("delete_policy", _, socket) do
    socket = assign(socket, :confirm, nil)

    if socket.assigns.can_edit? do
      case PolicyContext.delete_policy(socket.assigns.policy) do
        {:ok, _} ->
          log_audit(socket, "deleted", socket.assigns.policy)

          {:noreply,
           socket
           |> put_flash(:info, "Policy deleted.")
           |> redirect(
             to:
               scope_policies_path(
                 socket.assigns.scope,
                 socket.assigns.workspace,
                 socket.assigns.project,
                 socket.assigns.env
               )
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not delete policy.")}
      end
    else
      {:noreply, socket}
    end
  end

  defp do_save(socket, params) do
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

        case PolicyContext.update_policy(socket.assigns.policy, attrs) do
          {:ok, policy} ->
            log_audit(socket, "updated", policy)

            {:noreply,
             socket
             |> assign(:policy, policy)
             |> assign(:rego_initial, policy.rego_source)
             |> put_flash(:info, "Policy saved.")
             |> push_patch(to: ~p"/admin/policies/#{policy.uuid}")}

          {:error, changeset} ->
            msg =
              changeset.errors
              |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)
              |> Enum.join("; ")

            {:noreply, assign(socket, :form_error, msg)}
        end
    end
  end

  # -- Audit logging (mirror PolicyLive.log_audit/3) --

  defp log_audit(socket, action, %Policy{} = policy) do
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

  # -- Live validation against OPA (same shape as PolicyLive) --

  defp validate_async(socket, rego) do
    if ref = socket.assigns[:validate_ref], do: Process.cancel_timer(ref)

    new_ref = Process.send_after(self(), {:run_validate, rego}, @validate_debounce_ms)

    socket
    |> assign(:validate_ref, new_ref)
    |> assign(:validation, :validating)
  end

  @impl true
  def handle_info({:run_validate, rego}, socket) do
    if rego == socket.assigns.rego_buffer do
      result =
        case PolicyEngine.validate(rego) do
          :ok -> :ok
          {:invalid, errors} -> {:invalid, errors}
          {:error, _} -> {:warning, "OPA is unreachable, can't validate this rego."}
        end

      {:noreply, assign(socket, :validation, result) |> assign(:validate_ref, nil)}
    else
      {:noreply, socket}
    end
  end
end

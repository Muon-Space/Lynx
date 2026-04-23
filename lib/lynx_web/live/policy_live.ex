defmodule LynxWeb.PolicyLive do
  @moduledoc """
  Manage OPA Rego policies attached to a project or a specific environment
  (issue #38). Routed twice so the same LV serves both scopes:

      /admin/projects/:project_uuid/policies                       — project-scoped
      /admin/projects/:project_uuid/environments/:env_uuid/policies — env-scoped

  Uses `LiveMonacoEditor` for the rego source field with our custom
  `rego` Monarch language registered in `assets/js/rego_lang.js`.

  Server-side perm: `project:manage` for the project view, `env:manage`
  for the env view — same model used elsewhere for "manage the config
  under this scope".
  """
  use LynxWeb, :live_view

  alias Lynx.Context.{EnvironmentContext, PolicyContext, ProjectContext, RoleContext}

  @impl true
  def mount(params, _session, socket) do
    case load_scope(params) do
      {:ok, scope_assigns} ->
        if can_manage?(socket.assigns.current_user, scope_assigns) do
          {:ok,
           socket
           |> assign(scope_assigns)
           |> assign(:policies, list_policies(scope_assigns))
           |> assign(:editing, nil)
           |> assign(:show_form?, false)
           |> assign(:form_error, nil)}
        else
          {:ok,
           socket
           |> put_flash(:error, "You don't have permission to manage policies here.")
           |> redirect(to: ~p"/admin/projects/#{scope_assigns.project.uuid}")}
        end

      :not_found ->
        {:ok, socket |> put_flash(:error, "Not found.") |> redirect(to: ~p"/admin/workspaces")}
    end
  end

  defp load_scope(%{"project_uuid" => p_uuid, "env_uuid" => e_uuid}) do
    with project when not is_nil(project) <- ProjectContext.get_project_by_uuid(p_uuid),
         env when not is_nil(env) <-
           EnvironmentContext.get_env_by_uuid_project(project.id, e_uuid) do
      {:ok, %{scope: :env, project: project, env: env}}
    else
      _ -> :not_found
    end
  end

  defp load_scope(%{"project_uuid" => p_uuid}) do
    case ProjectContext.get_project_by_uuid(p_uuid) do
      nil -> :not_found
      project -> {:ok, %{scope: :project, project: project, env: nil}}
    end
  end

  defp can_manage?(user, %{scope: :env, project: project}),
    do: RoleContext.can?(user, project, "env:manage")

  defp can_manage?(user, %{scope: :project, project: project}),
    do: RoleContext.can?(user, project, "project:manage")

  defp list_policies(%{scope: :env, env: env}),
    do: PolicyContext.list_policies_by_environment(env.id)

  defp list_policies(%{scope: :project, project: project}),
    do: PolicyContext.list_policies_by_project(project.id)

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current_user={@current_user} active="" />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header
        title={"Policies — #{scope_label(@scope, @project, @env)}"}
        subtitle="OPA Rego policies evaluated for every plan upload at this scope."
      />

      <div class="mb-4 flex items-center justify-between">
        <.link
          navigate={back_path(@scope, @project, @env)}
          class="text-sm text-clickable hover:text-clickable-hover"
        >
          ← Back
        </.link>
        <.button :if={!@show_form?} phx-click="new" variant="primary" size="sm">
          Add Policy
        </.button>
      </div>

      <.card :if={@show_form?} class="mb-6">
        <h3 class="text-lg font-semibold mb-4">
          {if @editing, do: "Edit Policy", else: "New Policy"}
        </h3>

        <form phx-submit="save" phx-change="validate" class="space-y-4">
          <.input name="name" label="Name" value={form_value(@editing, :name)} required />
          <.input name="description" label="Description" value={form_value(@editing, :description)} />
          <.input
            name="enabled"
            type="checkbox"
            label="Enabled"
            checked={if @editing, do: @editing.enabled, else: true}
          />

          <div>
            <label class="block text-sm font-medium text-secondary mb-1">Rego source</label>
            <p class="text-xs text-muted mb-2">
              Define a <code>deny contains msg if</code> rule that emits violation strings (OPA 1.0+ syntax).
              The <code>package</code> line is rewritten to a Lynx-controlled namespace on save.
            </p>
            <LiveMonacoEditor.code_editor
              id="rego-editor"
              path="policy.rego"
              value={form_value(@editing, :rego_source) || @rego_default}
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
          </div>

          <p :if={@form_error} class="text-sm text-flash-error-text">{@form_error}</p>

          <div class="flex gap-2">
            <.button type="submit" variant="primary">
              {if @editing, do: "Save", else: "Create"}
            </.button>
            <.button phx-click="cancel" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.card>

      <.card>
        <.table rows={@policies} empty_message="No policies attached to this scope yet.">
          <:col :let={p} label="Name">{p.name}</:col>
          <:col :let={p} label="Description">{policy_description(p)}</:col>
          <:col :let={p} label="Status">
            <.badge color={if p.enabled, do: "green", else: "gray"}>
              {if p.enabled, do: "Enabled", else: "Disabled"}
            </.badge>
          </:col>
          <:action :let={p}>
            <.button phx-click="edit" phx-value-uuid={p.uuid} variant="ghost" size="sm">Edit</.button>
            <.button
              phx-click="confirm_delete"
              phx-value-uuid={p.uuid}
              variant="ghost"
              size="sm"
            >Delete</.button>
          </:action>
        </.table>
      </.card>
    </div>
    """
  end

  defp scope_label(:project, project, _), do: project.name
  defp scope_label(:env, project, env), do: "#{project.name} / #{env.name}"

  defp back_path(:project, project, _), do: ~p"/admin/projects/#{project.uuid}"

  defp back_path(:env, project, env),
    do: ~p"/admin/projects/#{project.uuid}/environments/#{env.uuid}"

  defp form_value(nil, _), do: ""
  defp form_value(policy, field), do: Map.get(policy, field) || ""

  defp policy_description(%{description: ""}), do: "—"
  defp policy_description(%{description: nil}), do: "—"
  defp policy_description(%{description: d}), do: d

  # -- Events --

  @impl true
  def handle_event("new", _, socket) do
    {:noreply,
     socket
     |> assign(:editing, nil)
     |> assign(:show_form?, true)
     |> assign(:rego_buffer, default_rego())
     |> assign(:rego_default, default_rego())
     |> assign(:form_error, nil)}
  end

  def handle_event("edit", %{"uuid" => uuid}, socket) do
    case PolicyContext.get_policy_by_uuid(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, "Policy not found.")}

      policy ->
        {:noreply,
         socket
         |> assign(:editing, policy)
         |> assign(:show_form?, true)
         |> assign(:rego_buffer, policy.rego_source)
         |> assign(:rego_default, policy.rego_source)
         |> assign(:form_error, nil)}
    end
  end

  def handle_event("cancel", _, socket) do
    {:noreply,
     socket
     |> assign(:editing, nil)
     |> assign(:show_form?, false)
     |> assign(:form_error, nil)}
  end

  # The editor pushes its full value via the `change` callback.
  def handle_event("set_rego", %{"value" => value}, socket) do
    {:noreply, assign(socket, :rego_buffer, value)}
  end

  # Ignore phx-change events sourced from the Monaco editor field —
  # documented LiveMonacoEditor footgun (only sends partial content).
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

      true ->
        attrs = %{
          name: name,
          description: description,
          rego_source: rego,
          enabled: enabled
        }

        result =
          case socket.assigns.editing do
            nil ->
              attrs =
                attrs
                |> Map.put(:project_id, project_id_for_scope(socket.assigns))
                |> Map.put(:environment_id, env_id_for_scope(socket.assigns))

              PolicyContext.create_policy(PolicyContext.new_policy(attrs))

            existing ->
              PolicyContext.update_policy(existing, attrs)
          end

        case result do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:show_form?, false)
             |> assign(:editing, nil)
             |> assign(:form_error, nil)
             |> assign(:policies, list_policies(socket.assigns))
             |> put_flash(:info, "Policy saved.")}

          {:error, changeset} ->
            msg =
              changeset.errors
              |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)
              |> Enum.join("; ")

            {:noreply, assign(socket, :form_error, msg)}
        end
    end
  end

  def handle_event("confirm_delete", %{"uuid" => uuid}, socket) do
    case PolicyContext.get_policy_by_uuid(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, "Policy not found.")}

      policy ->
        case PolicyContext.delete_policy(policy) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:policies, list_policies(socket.assigns))
             |> put_flash(:info, "Policy deleted.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not delete policy.")}
        end
    end
  end

  defp project_id_for_scope(%{scope: :project, project: project}), do: project.id
  defp project_id_for_scope(_), do: nil
  defp env_id_for_scope(%{scope: :env, env: env}), do: env.id
  defp env_id_for_scope(_), do: nil

  defp default_rego do
    """
    package main

    # Emit a violation message per disallowed change. Lynx aggregates these
    # across all attached policies into the plan_check `outcome`. Uses
    # OPA 1.0+ partial-set syntax (`contains ... if`).
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

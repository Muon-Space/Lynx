defmodule LynxWeb.ProjectLive do
  use LynxWeb, :live_view

  alias Lynx.Module.ProjectModule
  alias Lynx.Module.EnvironmentModule
  alias Lynx.Module.StateModule
  alias Lynx.Module.LockModule
  alias Lynx.Module.OIDCBackendModule
  alias Lynx.Module.AuditModule
  alias Lynx.Context.EnvironmentContext

  on_mount {LynxWeb.LiveAuth, :require_auth}

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    case ProjectModule.get_project_by_uuid(uuid) do
      {:not_found, _} ->
        {:ok, redirect(socket, to: "/admin/projects")}

      {:ok, project} ->
        workspace =
          if project.workspace_id,
            do: Lynx.Context.WorkspaceContext.get_workspace_by_id(project.workspace_id)

        teams = ProjectModule.get_project_teams(project.id)
        environments = EnvironmentContext.get_project_envs(project.id, 0, 10000)

        envs_with_info =
          Enum.map(environments, fn env ->
            state_count = StateModule.count_states(env.id)
            is_locked = EnvironmentModule.is_environment_locked(env.id)

            %{
              id: env.id,
              uuid: env.uuid,
              name: env.name,
              slug: env.slug,
              username: env.username,
              secret: env.secret,
              state_version: if(state_count > 0, do: "v#{state_count}", else: "v0"),
              is_locked: is_locked,
              inserted_at: env.inserted_at
            }
          end)

        socket =
          socket
          |> assign(:project, project)
          |> assign(:project_uuid, uuid)
          |> assign(:workspace, workspace)
          |> assign(:teams, teams)
          |> assign(:environments, envs_with_info)
          |> assign(:show_add_env, false)
          |> assign(:add_env_slug, "")
          |> assign(:editing_env, nil)
          |> assign(:show_oidc_rules, nil)
          |> assign(:oidc_rules, [])
          |> assign(:oidc_providers, OIDCBackendModule.list_providers())
          |> assign(:show_add_rule, false)

        socket = assign(socket, :confirm, nil)
        {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.confirm_dialog :if={@confirm} message={@confirm.message} confirm_event={@confirm.event} confirm_value={@confirm.value} />
    <.nav current_user={@current_user} active="workspaces" />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header title={@project.name} subtitle={@project.description} />
      <div class="flex items-center justify-between mb-4">
        <nav class="flex items-center gap-2 text-sm text-gray-500 dark:text-gray-400">
          <a href="/admin/workspaces" class="hover:text-gray-700 dark:hover:text-gray-200">Workspaces</a>
          <span>/</span>
          <a :if={@workspace} href={"/admin/workspaces/#{@workspace.uuid}"} class="hover:text-gray-700 dark:hover:text-gray-200">{@workspace.name}</a>
          <span :if={@workspace}>/</span>
          <span class="text-gray-900 dark:text-white font-medium">{@project.name}</span>
        </nav>
        <.button phx-click="show_add_env" variant="primary">+ Add Environment</.button>
      </div>

      <%!-- Add Environment Modal --%>
      <.modal :if={@show_add_env} id="add-env" show on_close="hide_add_env">
        <h3 class="text-lg font-semibold mb-4">Add Environment</h3>
        <form phx-submit="create_env" phx-change="env_form_change" class="space-y-4">
          <.input name="name" label="Name" value="" required />
          <.input name="slug" label="Slug" value={@add_env_slug} required />
          <.input name="username" label="Username" value={random_string(8)} required />
          <.input name="secret" label="Secret" value={random_string(16)} required />
          <div class="flex gap-3 pt-2">
            <.button type="submit" variant="primary">Create</.button>
            <.button phx-click="hide_add_env" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <%!-- Edit Environment Modal --%>
      <.modal :if={@editing_env} id="edit-env" show on_close="hide_edit_env">
        <h3 class="text-lg font-semibold mb-4">Edit Environment</h3>
        <form phx-submit="update_env" class="space-y-4">
          <.input name="name" label="Name" value={@editing_env.name} required />
          <.input name="slug" label="Slug" value={@editing_env.slug} required />
          <.input name="username" label="Username" value={@editing_env.username} required />
          <.input name="secret" label="Secret" value={@editing_env.secret} required />
          <div class="flex gap-3 pt-2">
            <.button type="submit" variant="primary">Update</.button>
            <.button phx-click="hide_edit_env" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <%!-- OIDC Rules Modal --%>
      <.modal :if={@show_oidc_rules} id="oidc-rules" show on_close="hide_oidc_rules">
        <h3 class="text-lg font-semibold mb-4">OIDC Access Rules — {@show_oidc_rules.name}</h3>

        <div :if={@show_add_rule} class="border border-gray-200 dark:border-gray-700 rounded-lg p-4 mb-4">
          <form phx-submit="create_rule" class="space-y-3">
            <.input name="provider_id" label="Provider" type="select" prompt="Select provider" options={Enum.map(@oidc_providers, &{&1.name, &1.uuid})} value="" required />
            <.input name="rule_name" label="Rule Name" value="" required placeholder="prod-deploy" />
            <.input name="claims" label="Claims (claim=value, comma separated)" value="" required placeholder="repository=myorg/infra,environment=production" hint="All claims must match (AND logic)" />
            <div class="flex gap-3">
              <.button type="submit" variant="primary" size="sm">Save Rule</.button>
              <.button phx-click="hide_add_rule" variant="secondary" size="sm">Cancel</.button>
            </div>
          </form>
        </div>

        <div :if={!@show_add_rule} class="flex justify-end mb-3">
          <.button phx-click="show_add_rule" variant="primary" size="sm">Add Rule</.button>
        </div>

        <.table rows={@oidc_rules} empty_message="No OIDC access rules for this environment.">
          <:col :let={r} label="Name">{r.name}</:col>
          <:col :let={r} label="Claims">
            <div :for={cr <- Jason.decode!(r.claim_rules)}>
              <code class="text-xs">{cr["claim"]} {cr["operator"]} {cr["value"]}</code>
            </div>
          </:col>
          <:action :let={r}>
            <.button phx-click="confirm_action" phx-value-event="delete_rule" phx-value-message="Delete this rule?" phx-value-uuid={r.uuid} variant="ghost" size="sm">Delete</.button>
          </:action>
        </.table>
      </.modal>

      <%!-- Environments Table --%>
      <.card>
        <.table rows={@environments} row_click={fn env -> JS.push("view_env", value: %{uuid: env.uuid}) end}>
          <:col :let={env} label="Name"><span class="font-medium text-blue-600">{env.name}</span></:col>
          <:col :let={env} label="Lock Status">
            <span
              class="cursor-pointer"
              phx-click="confirm_action"
              phx-value-event={if env.is_locked, do: "force_unlock", else: "force_lock"}
              phx-value-uuid={env.uuid}
              phx-value-message={if env.is_locked, do: "Force unlock this environment?", else: "Lock this environment?"}
            >
              <.badge color={if env.is_locked, do: "red", else: "green"}>
                {if env.is_locked, do: "Locked", else: "Not Locked"}
              </.badge>
            </span>
          </:col>
          <:col :let={env} label="State">{env.state_version}</:col>
          <:col :let={env} label="Created">
            <span class="text-xs text-gray-500">{Calendar.strftime(env.inserted_at, "%Y-%m-%d %H:%M")}</span>
          </:col>
          <:action :let={env}>
            <.button phx-click="show_oidc_rules" phx-value-uuid={env.uuid} variant="ghost" size="sm">OIDC</.button>
            <.button phx-click="edit_env" phx-value-uuid={env.uuid} variant="ghost" size="sm">Edit</.button>
            <.button phx-click="confirm_action" phx-value-event="delete_env" phx-value-message="Delete this environment?" phx-value-uuid={env.uuid} variant="ghost" size="sm">Delete</.button>
          </:action>
        </.table>
      </.card>
    </div>
    """
  end

  # -- Environment CRUD --
  @impl true
  def handle_event("confirm_action", params, socket) do
    {:noreply,
     assign(socket, :confirm, %{
       message: params["message"],
       event: params["event"],
       value: %{uuid: params["uuid"]}
     })}
  end

  def handle_event("cancel_confirm", _, socket), do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("show_add_env", _, socket),
    do: {:noreply, assign(socket, show_add_env: true, add_env_slug: "")}

  def handle_event("hide_add_env", _, socket),
    do: {:noreply, assign(socket, :show_add_env, false)}

  def handle_event("env_form_change", %{"name" => name}, socket) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")

    {:noreply, assign(socket, :add_env_slug, slug)}
  end

  def handle_event("hide_edit_env", _, socket), do: {:noreply, assign(socket, :editing_env, nil)}

  def handle_event("view_env", %{"uuid" => uuid}, socket) do
    {:noreply,
     push_navigate(socket,
       to: "/admin/projects/#{socket.assigns.project_uuid}/environments/#{uuid}"
     )}
  end

  def handle_event("create_env", params, socket) do
    case EnvironmentModule.create_environment(%{
           name: params["name"],
           slug: params["slug"],
           username: params["username"],
           secret: params["secret"],
           project_id: socket.assigns.project.uuid
         }) do
      {:ok, env} ->
        AuditModule.log_user(
          socket.assigns.current_user,
          "created",
          "environment",
          env.uuid,
          env.name
        )

        {:noreply,
         socket
         |> assign(:show_add_env, false)
         |> put_flash(:info, "Environment created")
         |> reload_envs()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("edit_env", %{"uuid" => uuid}, socket) do
    env = Enum.find(socket.assigns.environments, &(&1.uuid == uuid))
    {:noreply, assign(socket, :editing_env, env)}
  end

  def handle_event("update_env", params, socket) do
    case EnvironmentModule.update_environment(%{
           uuid: socket.assigns.editing_env.uuid,
           name: params["name"],
           slug: params["slug"],
           username: params["username"],
           secret: params["secret"]
         }) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:editing_env, nil)
         |> put_flash(:info, "Environment updated")
         |> reload_envs()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("delete_env", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)

    case EnvironmentModule.delete_environment_by_uuid(socket.assigns.project.uuid, uuid) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Environment deleted") |> reload_envs()}
      _ -> {:noreply, put_flash(socket, :error, "Failed to delete")}
    end
  end

  # -- Lock/Unlock --
  def handle_event("force_lock", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)

    case EnvironmentContext.get_env_id_with_uuid(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, "Environment not found")}

      env_id ->
        LockModule.force_lock(env_id, socket.assigns.current_user.name)
        AuditModule.log_user(socket.assigns.current_user, "locked", "environment", uuid)
        {:noreply, socket |> put_flash(:info, "Environment locked") |> reload_envs()}
    end
  end

  def handle_event("force_unlock", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)

    case EnvironmentContext.get_env_id_with_uuid(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, "Environment not found")}

      env_id ->
        LockModule.force_unlock(env_id)
        AuditModule.log_user(socket.assigns.current_user, "unlocked", "environment", uuid)
        {:noreply, socket |> put_flash(:info, "Environment unlocked") |> reload_envs()}
    end
  end

  # -- OIDC Rules --
  def handle_event("show_oidc_rules", %{"uuid" => uuid}, socket) do
    env = Enum.find(socket.assigns.environments, &(&1.uuid == uuid))
    rules = OIDCBackendModule.list_rules_by_environment(env.id)
    {:noreply, assign(socket, show_oidc_rules: env, oidc_rules: rules, show_add_rule: false)}
  end

  def handle_event("hide_oidc_rules", _, socket) do
    {:noreply, assign(socket, show_oidc_rules: nil, oidc_rules: [])}
  end

  def handle_event("show_add_rule", _, socket),
    do: {:noreply, assign(socket, :show_add_rule, true)}

  def handle_event("hide_add_rule", _, socket),
    do: {:noreply, assign(socket, :show_add_rule, false)}

  def handle_event("create_rule", params, socket) do
    provider = Lynx.Context.OIDCProviderContext.get_provider_by_uuid(params["provider_id"])

    claim_rules =
      params["claims"]
      |> String.split(",")
      |> Enum.map(fn pair ->
        case String.split(String.trim(pair), "=", parts: 2) do
          [k, v] -> %{"claim" => String.trim(k), "operator" => "eq", "value" => String.trim(v)}
          _ -> nil
        end
      end)
      |> Enum.filter(& &1)
      |> Jason.encode!()

    if provider do
      case OIDCBackendModule.create_rule(%{
             name: params["rule_name"],
             claim_rules: claim_rules,
             provider_id: provider.id,
             environment_id: socket.assigns.show_oidc_rules.id
           }) do
        {:ok, rule} ->
          AuditModule.log_user(
            socket.assigns.current_user,
            "created",
            "oidc_rule",
            rule.uuid,
            params["rule_name"]
          )

          rules = OIDCBackendModule.list_rules_by_environment(socket.assigns.show_oidc_rules.id)

          {:noreply,
           socket
           |> assign(:oidc_rules, rules)
           |> assign(:show_add_rule, false)
           |> put_flash(:info, "Rule created")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to create rule")}
      end
    else
      {:noreply, put_flash(socket, :error, "Provider not found")}
    end
  end

  def handle_event("delete_rule", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)
    AuditModule.log_user(socket.assigns.current_user, "deleted", "oidc_rule", uuid)
    OIDCBackendModule.delete_rule(uuid)
    rules = OIDCBackendModule.list_rules_by_environment(socket.assigns.show_oidc_rules.id)
    {:noreply, socket |> assign(:oidc_rules, rules) |> put_flash(:info, "Rule deleted")}
  end

  # -- Helpers --
  defp reload_envs(socket) do
    environments = EnvironmentContext.get_project_envs(socket.assigns.project.id, 0, 10000)

    envs_with_info =
      Enum.map(environments, fn env ->
        state_count = StateModule.count_states(env.id)
        is_locked = EnvironmentModule.is_environment_locked(env.id)

        %{
          id: env.id,
          uuid: env.uuid,
          name: env.name,
          slug: env.slug,
          username: env.username,
          secret: env.secret,
          state_version: if(state_count > 0, do: "v#{state_count}", else: "v0"),
          is_locked: is_locked,
          inserted_at: env.inserted_at
        }
      end)

    assign(socket, :environments, envs_with_info)
  end

  defp random_string(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, length)
  end
end

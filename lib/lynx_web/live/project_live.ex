defmodule LynxWeb.ProjectLive do
  use LynxWeb, :live_view

  alias Lynx.Context.ProjectContext
  alias Lynx.Context.EnvironmentContext
  alias Lynx.Context.StateContext
  alias Lynx.Context.LockContext
  alias Lynx.Service.OIDCBackend
  alias Lynx.Context.AuditContext
  alias Lynx.Context.RoleContext
  alias Lynx.Context.TeamContext
  alias Lynx.Context.UserContext
  alias Lynx.Context.EnvironmentContext
  alias Lynx.Context.ProjectContext
  alias Lynx.Context.RoleContext
  alias Lynx.Context.UserProjectContext

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    case ProjectContext.fetch_project_by_uuid(uuid) do
      {:not_found, _} ->
        {:ok, redirect(socket, to: "/admin/projects")}

      {:ok, project} ->
        workspace =
          if project.workspace_id,
            do: Lynx.Context.WorkspaceContext.get_workspace_by_id(project.workspace_id)

        environments =
          EnvironmentContext.get_project_envs(
            project.id,
            0,
            LynxWeb.Limits.child_collection_max()
          )

        envs_with_info =
          Enum.map(environments, fn env ->
            state_count = StateContext.count_states(env.id)
            is_locked = EnvironmentContext.is_environment_locked(env.id)

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

        roles = RoleContext.list_roles()
        viewer_perms = RoleContext.effective_permissions(socket.assigns.current_user, project)

        socket =
          socket
          |> assign(:project, project)
          |> assign(:project_uuid, uuid)
          |> assign(:workspace, workspace)
          |> assign(:environments, envs_with_info)
          |> assign(:show_add_env, false)
          |> assign(:add_env_slug, "")
          |> assign(:editing_env, nil)
          |> assign(:show_oidc_rules, nil)
          |> assign(:oidc_rules, [])
          |> assign(:oidc_providers, OIDCBackend.list_providers())
          |> assign(:show_add_rule, false)
          |> assign(:rule_provider_id, "")
          |> assign(:rule_role_id, default_role_id(roles, "applier"))
          |> assign(:roles, roles)
          |> assign(:viewer_perms, viewer_perms)
          |> assign(:all_teams, TeamContext.get_teams(0, LynxWeb.Limits.dropdown_max()))
          |> assign(:all_users, UserContext.get_users(0, LynxWeb.Limits.dropdown_max()))
          |> assign(:add_team_id, "")
          |> assign(:add_team_role_id, default_role_id(roles, "applier"))
          |> assign(:add_user_id, "")
          |> assign(:add_user_role_id, default_role_id(roles, "planner"))
          |> assign(:confirm, nil)
          |> reload_access()

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
        <nav class="flex items-center gap-2 text-sm text-secondary">
          <a href="/admin/workspaces" class="hover:text-foreground">Workspaces</a>
          <span>/</span>
          <a :if={@workspace} href={"/admin/workspaces/#{@workspace.uuid}"} class="hover:text-foreground">{@workspace.name}</a>
          <span :if={@workspace}>/</span>
          <span class="text-foreground font-medium">{@project.name}</span>
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

        <div :if={@show_add_rule} class="border border-border rounded-lg p-4 mb-4">
          <form phx-submit="create_rule" phx-change="rule_form_change" class="space-y-3">
            <.input name="provider_id" label="Provider" type="select" prompt="Select provider" options={Enum.map(@oidc_providers, &{&1.name, &1.uuid})} value={@rule_provider_id} required hint={if @rule_provider_id == "", do: "Provider is required."} />
            <.input name="rule_name" label="Rule Name" value="" required placeholder="prod-deploy" />
            <.input name="role_id" label="Role" type="select" options={role_options(@roles)} value={to_string(@rule_role_id)} required hint="Permissions granted when this rule matches" />
            <.input name="claims" label="Claims (claim=value, comma separated)" value="" required placeholder="repository=myorg/infra,environment=production" hint="All claims must match (AND logic)" />
            <div class="flex gap-3">
              <.button type="submit" variant="primary" size="sm" disabled={@rule_provider_id == ""} class="disabled:opacity-50 disabled:cursor-not-allowed">Save Rule</.button>
              <.button phx-click="hide_add_rule" variant="secondary" size="sm">Cancel</.button>
            </div>
          </form>
        </div>

        <div :if={!@show_add_rule} class="flex justify-end mb-3">
          <.button phx-click="show_add_rule" variant="primary" size="sm">Add Rule</.button>
        </div>

        <.table rows={@oidc_rules} empty_message="No OIDC access rules for this environment.">
          <:col :let={r} label="Name">{r.name}</:col>
          <:col :let={r} label="Provider">
            <.badge color="blue">{provider_name_for(@oidc_providers, r.provider_id)}</.badge>
          </:col>
          <:col :let={r} label="Role">
            <.badge color="purple">{role_name_for(@roles, r.role_id)}</.badge>
          </:col>
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
          <:col :let={env} label="Name"><span class="font-medium text-clickable">{env.name}</span></:col>
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
            <span class="text-xs text-muted">{Calendar.strftime(env.inserted_at, "%Y-%m-%d %H:%M")}</span>
          </:col>
          <:action :let={env}>
            <.button phx-click="show_oidc_rules" phx-value-uuid={env.uuid} variant="ghost" size="sm">OIDC</.button>
            <.button phx-click="edit_env" phx-value-uuid={env.uuid} variant="ghost" size="sm">Edit</.button>
            <.button phx-click="confirm_action" phx-value-event="delete_env" phx-value-message="Delete this environment?" phx-value-uuid={env.uuid} variant="ghost" size="sm">Delete</.button>
          </:action>
        </.table>
      </.card>

      <%!-- Project Access --%>
      <div :if={can_manage_access?(@viewer_perms, @current_user)} class="mt-6">
        <.card>
          <h3 class="text-base font-semibold mb-1">Project Access</h3>
          <p class="text-sm text-muted mb-4">Roles cascade to every environment in this project. OIDC rules carry their own role per-environment.</p>

          <div class="mb-6">
            <h4 class="text-sm font-medium mb-2">Teams</h4>
            <.table rows={@team_assignments} empty_message="No teams attached to this project.">
              <:col :let={a} label="Team">{a.team.name}</:col>
              <:col :let={a} label="Role">
                <form phx-change="change_team_role" class="inline-block w-40">
                  <input type="hidden" name="team_id" value={a.team.id} />
                  <.input
                    id={"team-role-#{a.team.id}"}
                    name="role_id"
                    type="select"
                    options={role_options(@roles)}
                    value={to_string(a.role_id)}
                  />
                </form>
              </:col>
              <:action :let={a}>
                <.button phx-click="confirm_action" phx-value-event="remove_team_access" phx-value-message={"Remove team " <> a.team.name <> " from this project?"} phx-value-uuid={a.team.uuid} variant="ghost" size="sm">Remove</.button>
              </:action>
            </.table>

            <form phx-submit="add_team_access" phx-change="add_team_form_change" class="mt-3 flex items-end gap-2">
              <div class="flex-1">
                <.input
                  id="add-team-id"
                  name="team_id"
                  type="select"
                  label="Add team"
                  prompt="Select a team"
                  options={Enum.map(unattached_teams(@all_teams, @team_assignments), &{&1.name, &1.uuid})}
                  value={@add_team_id}
                />
              </div>
              <div class="w-40">
                <.input
                  id="add-team-role"
                  name="role_id"
                  type="select"
                  label="Role"
                  options={role_options(@roles)}
                  value={to_string(@add_team_role_id)}
                />
              </div>
              <.button type="submit" variant="primary" size="sm" disabled={@add_team_id == ""} class="disabled:opacity-50 disabled:cursor-not-allowed">Add</.button>
            </form>
          </div>

          <div>
            <h4 class="text-sm font-medium mb-2">Individual users</h4>
            <.table rows={@user_assignments} empty_message="No individual user grants on this project.">
              <:col :let={a} label="User">{a.user.name} <span class="text-xs text-muted">({a.user.email})</span></:col>
              <:col :let={a} label="Role">
                <form phx-change="change_user_role" class="inline-block w-40">
                  <input type="hidden" name="user_id" value={a.user.id} />
                  <.input
                    id={"user-role-#{a.user.id}"}
                    name="role_id"
                    type="select"
                    options={role_options(@roles)}
                    value={to_string(a.role_id)}
                  />
                </form>
              </:col>
              <:action :let={a}>
                <.button phx-click="confirm_action" phx-value-event="remove_user_access" phx-value-message={"Remove " <> a.user.email <> " from this project?"} phx-value-uuid={a.user.uuid} variant="ghost" size="sm">Remove</.button>
              </:action>
            </.table>

            <form phx-submit="add_user_access" phx-change="add_user_form_change" class="mt-3 flex items-end gap-2">
              <div class="flex-1">
                <.input
                  id="add-user-id"
                  name="user_id"
                  type="select"
                  label="Add user"
                  prompt="Select a user"
                  options={Enum.map(unattached_users(@all_users, @user_assignments), &{"#{&1.name} (#{&1.email})", &1.uuid})}
                  value={@add_user_id}
                />
              </div>
              <div class="w-40">
                <.input
                  id="add-user-role"
                  name="role_id"
                  type="select"
                  label="Role"
                  options={role_options(@roles)}
                  value={to_string(@add_user_role_id)}
                />
              </div>
              <.button type="submit" variant="primary" size="sm" disabled={@add_user_id == ""} class="disabled:opacity-50 disabled:cursor-not-allowed">Add</.button>
            </form>
          </div>
        </.card>
      </div>
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
    case EnvironmentContext.create_environment(%{
           name: params["name"],
           slug: params["slug"],
           username: params["username"],
           secret: params["secret"],
           project_id: socket.assigns.project.uuid
         }) do
      {:ok, env} ->
        AuditContext.log_user(
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
    case EnvironmentContext.update_environment(%{
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

    case EnvironmentContext.delete_environment_by_uuid(socket.assigns.project.uuid, uuid) do
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
        LockContext.force_lock(env_id, socket.assigns.current_user.name)
        AuditContext.log_user(socket.assigns.current_user, "locked", "environment", uuid)
        {:noreply, socket |> put_flash(:info, "Environment locked") |> reload_envs()}
    end
  end

  def handle_event("force_unlock", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)

    case EnvironmentContext.get_env_id_with_uuid(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, "Environment not found")}

      env_id ->
        LockContext.force_unlock(env_id)
        AuditContext.log_user(socket.assigns.current_user, "unlocked", "environment", uuid)
        {:noreply, socket |> put_flash(:info, "Environment unlocked") |> reload_envs()}
    end
  end

  # -- OIDC Rules --
  def handle_event("show_oidc_rules", %{"uuid" => uuid}, socket) do
    env = Enum.find(socket.assigns.environments, &(&1.uuid == uuid))
    rules = OIDCBackend.list_rules_by_environment(env.id)
    {:noreply, assign(socket, show_oidc_rules: env, oidc_rules: rules, show_add_rule: false)}
  end

  def handle_event("hide_oidc_rules", _, socket) do
    {:noreply, assign(socket, show_oidc_rules: nil, oidc_rules: [])}
  end

  def handle_event("show_add_rule", _, socket),
    do: {:noreply, socket |> assign(:show_add_rule, true) |> assign(:rule_provider_id, "")}

  def handle_event("hide_add_rule", _, socket),
    do: {:noreply, socket |> assign(:show_add_rule, false) |> assign(:rule_provider_id, "")}

  def handle_event("rule_form_change", params, socket) do
    socket =
      socket
      |> assign(:rule_provider_id, params["provider_id"] || socket.assigns.rule_provider_id)
      |> assign(
        :rule_role_id,
        parse_role_id(params["role_id"], socket.assigns.rule_role_id)
      )

    {:noreply, socket}
  end

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

    role_id = parse_role_id(params["role_id"], socket.assigns.rule_role_id)

    cond do
      provider == nil ->
        {:noreply, put_flash(socket, :error, "Provider not found")}

      not can_manage_oidc_rules?(socket.assigns) ->
        {:noreply, put_flash(socket, :error, "You do not have permission to manage OIDC rules")}

      true ->
        case OIDCBackend.create_rule(%{
               name: params["rule_name"],
               claim_rules: claim_rules,
               provider_id: provider.id,
               environment_id: socket.assigns.show_oidc_rules.id,
               role_id: role_id
             }) do
          {:ok, rule} ->
            AuditContext.log_user(
              socket.assigns.current_user,
              "created",
              "oidc_rule",
              rule.uuid,
              params["rule_name"]
            )

            rules = OIDCBackend.list_rules_by_environment(socket.assigns.show_oidc_rules.id)

            {:noreply,
             socket
             |> assign(:oidc_rules, rules)
             |> assign(:show_add_rule, false)
             |> assign(:rule_provider_id, "")
             |> assign(:rule_role_id, default_role_id(socket.assigns.roles, "applier"))
             |> put_flash(:info, "Rule created")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to create rule")}
        end
    end
  end

  def handle_event("delete_rule", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)

    if can_manage_oidc_rules?(socket.assigns) do
      AuditContext.log_user(socket.assigns.current_user, "deleted", "oidc_rule", uuid)
      OIDCBackend.delete_rule(uuid)
      rules = OIDCBackend.list_rules_by_environment(socket.assigns.show_oidc_rules.id)
      {:noreply, socket |> assign(:oidc_rules, rules) |> put_flash(:info, "Rule deleted")}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage OIDC rules")}
    end
  end

  # -- Project Access (teams + users) --
  def handle_event("add_team_form_change", params, socket) do
    {:noreply,
     socket
     |> assign(:add_team_id, params["team_id"] || "")
     |> assign(
       :add_team_role_id,
       parse_role_id(params["role_id"], socket.assigns.add_team_role_id)
     )}
  end

  def handle_event("add_user_form_change", params, socket) do
    {:noreply,
     socket
     |> assign(:add_user_id, params["user_id"] || "")
     |> assign(
       :add_user_role_id,
       parse_role_id(params["role_id"], socket.assigns.add_user_role_id)
     )}
  end

  def handle_event("add_team_access", params, socket) do
    with :ok <- ensure_can_manage_access(socket),
         %{} = team <- find_team_by_uuid(socket.assigns.all_teams, params["team_id"]) do
      role_id = parse_role_id(params["role_id"], socket.assigns.add_team_role_id)
      ProjectContext.add_project_to_team(socket.assigns.project.id, team.id, role_id)

      AuditContext.log_user(
        socket.assigns.current_user,
        "granted",
        "project_team",
        team.uuid,
        team.name
      )

      {:noreply,
       socket
       |> put_flash(:info, "Team access granted")
       |> assign(:add_team_id, "")
       |> reload_access()}
    else
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
      _ -> {:noreply, put_flash(socket, :error, "Team not found")}
    end
  end

  def handle_event("change_team_role", %{"team_id" => team_id, "role_id" => role_id}, socket) do
    case ensure_can_manage_access(socket) do
      :ok ->
        ProjectContext.set_project_team_role(
          socket.assigns.project.id,
          String.to_integer(team_id),
          String.to_integer(role_id)
        )

        {:noreply, socket |> put_flash(:info, "Team role updated") |> reload_access()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("remove_team_access", %{"uuid" => team_uuid}, socket) do
    socket = assign(socket, :confirm, nil)

    with :ok <- ensure_can_manage_access(socket),
         %{} = team <- find_team_by_uuid(socket.assigns.all_teams, team_uuid) do
      ProjectContext.remove_project_from_team(socket.assigns.project.id, team.id)

      AuditContext.log_user(
        socket.assigns.current_user,
        "revoked",
        "project_team",
        team.uuid,
        team.name
      )

      {:noreply, socket |> put_flash(:info, "Team removed") |> reload_access()}
    else
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
      _ -> {:noreply, put_flash(socket, :error, "Team not found")}
    end
  end

  def handle_event("add_user_access", params, socket) do
    with :ok <- ensure_can_manage_access(socket),
         %{} = user <- find_user_by_uuid(socket.assigns.all_users, params["user_id"]) do
      role_id = parse_role_id(params["role_id"], socket.assigns.add_user_role_id)
      UserProjectContext.assign_role(user.id, socket.assigns.project.id, role_id)

      AuditContext.log_user(
        socket.assigns.current_user,
        "granted",
        "user_project",
        user.uuid,
        user.email
      )

      {:noreply,
       socket
       |> put_flash(:info, "User access granted")
       |> assign(:add_user_id, "")
       |> reload_access()}
    else
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
      _ -> {:noreply, put_flash(socket, :error, "User not found")}
    end
  end

  def handle_event("change_user_role", %{"user_id" => user_id, "role_id" => role_id}, socket) do
    case ensure_can_manage_access(socket) do
      :ok ->
        UserProjectContext.assign_role(
          String.to_integer(user_id),
          socket.assigns.project.id,
          String.to_integer(role_id)
        )

        {:noreply, socket |> put_flash(:info, "User role updated") |> reload_access()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("remove_user_access", %{"uuid" => user_uuid}, socket) do
    socket = assign(socket, :confirm, nil)

    with :ok <- ensure_can_manage_access(socket),
         %{} = user <- find_user_by_uuid(socket.assigns.all_users, user_uuid) do
      UserProjectContext.remove(user.id, socket.assigns.project.id)

      AuditContext.log_user(
        socket.assigns.current_user,
        "revoked",
        "user_project",
        user.uuid,
        user.email
      )

      {:noreply, socket |> put_flash(:info, "User removed") |> reload_access()}
    else
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
      _ -> {:noreply, put_flash(socket, :error, "User not found")}
    end
  end

  # -- Helpers --
  defp reload_envs(socket) do
    environments =
      EnvironmentContext.get_project_envs(
        socket.assigns.project.id,
        0,
        LynxWeb.Limits.child_collection_max()
      )

    envs_with_info =
      Enum.map(environments, fn env ->
        state_count = StateContext.count_states(env.id)
        is_locked = EnvironmentContext.is_environment_locked(env.id)

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

  defp provider_name_for(providers, provider_id) do
    case Enum.find(providers, &(&1.id == provider_id)) do
      nil -> "(unknown)"
      provider -> provider.name
    end
  end

  defp role_name_for(roles, role_id) do
    case Enum.find(roles, &(&1.id == role_id)) do
      nil -> "(unknown)"
      role -> String.capitalize(role.name)
    end
  end

  defp role_options(roles) do
    Enum.map(roles, fn r -> {String.capitalize(r.name), r.id} end)
  end

  defp default_role_id(roles, name) do
    case Enum.find(roles, &(&1.name == name)) do
      nil -> nil
      r -> r.id
    end
  end

  defp parse_role_id(nil, fallback), do: fallback
  defp parse_role_id("", fallback), do: fallback

  defp parse_role_id(role_id, fallback) when is_binary(role_id) do
    case Integer.parse(role_id) do
      {id, ""} -> id
      _ -> fallback
    end
  end

  defp parse_role_id(_, fallback), do: fallback

  defp can_manage_access?(_viewer_perms, %{role: "super"}), do: true

  defp can_manage_access?(viewer_perms, _user) do
    RoleContext.has?(viewer_perms || MapSet.new(), "access:manage")
  end

  defp can_manage_oidc_rules?(%{current_user: %{role: "super"}}), do: true

  defp can_manage_oidc_rules?(%{viewer_perms: perms}) do
    RoleContext.has?(perms || MapSet.new(), "oidc_rule:manage")
  end

  defp ensure_can_manage_access(socket) do
    if can_manage_access?(socket.assigns.viewer_perms, socket.assigns.current_user) do
      :ok
    else
      {:error, "You do not have permission to manage project access"}
    end
  end

  defp unattached_teams(all_teams, assignments) do
    attached_ids = MapSet.new(assignments, & &1.team.id)
    Enum.reject(all_teams, &MapSet.member?(attached_ids, &1.id))
  end

  defp unattached_users(all_users, assignments) do
    attached_ids = MapSet.new(assignments, & &1.user.id)
    Enum.reject(all_users, &MapSet.member?(attached_ids, &1.id))
  end

  defp find_team_by_uuid(teams, uuid), do: Enum.find(teams, &(&1.uuid == uuid))
  defp find_user_by_uuid(users, uuid), do: Enum.find(users, &(&1.uuid == uuid))

  defp reload_access(socket) do
    project_id = socket.assigns.project.id

    team_assignments =
      project_id
      |> ProjectContext.list_project_team_assignments()
      |> Enum.map(fn {team, pt} -> %{team: team, role_id: pt.role_id} end)

    user_assignments =
      project_id
      |> UserProjectContext.list_user_assignments_for_project()
      |> Enum.map(fn {user, up} -> %{user: user, role_id: up.role_id} end)

    socket
    |> assign(:team_assignments, team_assignments)
    |> assign(:user_assignments, user_assignments)
  end
end

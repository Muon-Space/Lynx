defmodule LynxWeb.EnvironmentLive do
  use LynxWeb, :live_view

  alias Lynx.Context.ProjectContext
  alias Lynx.Context.LockContext
  alias Lynx.Service.Settings
  alias Lynx.Context.AuditContext
  alias Lynx.Context.EnvironmentContext
  alias Lynx.Context.PlanCheckContext
  alias Lynx.Context.PolicyContext
  alias Lynx.Context.StateContext
  alias Lynx.Context.RoleContext
  alias Lynx.Context.LockContext
  alias Lynx.Service.{OIDCBackend, PolicyGate}

  # `?oidc=1` from the role-detail page's "Manage" link opens the OIDC modal
  # on mount so the admin lands directly on the rules editor for this env.
  @impl true
  def handle_params(%{"oidc" => flag}, _uri, socket) when flag in ["1", "true"] do
    if can_manage_oidc_rules?(socket.assigns) do
      {:noreply,
       socket
       |> assign(:show_oidc, true)
       |> assign(:oidc_rules, OIDCBackend.list_rules_by_environment(socket.assigns.env.id))
       |> assign(:show_add_rule, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def mount(%{"project_uuid" => project_uuid, "env_uuid" => env_uuid}, _session, socket) do
    case ProjectContext.fetch_project_by_uuid(project_uuid) do
      {:not_found, _} ->
        {:ok, redirect(socket, to: "/admin/projects")}

      {:ok, project} ->
        case EnvironmentContext.get_env_by_uuid(env_uuid) do
          nil ->
            {:ok, redirect(socket, to: "/admin/projects/#{project_uuid}")}

          env ->
            workspace =
              if project.workspace_id,
                do: Lynx.Context.WorkspaceContext.get_workspace_by_id(project.workspace_id)

            app_url =
              Settings.get_config("app_url", "http://localhost:4000")
              |> String.trim_trailing("/")

            # Env-aware: per-env grant overrides apply when computing perms
            # for buttons specific to this env (lock/unlock/etc).
            viewer_perms =
              RoleContext.effective_permissions(socket.assigns.current_user, project, env)

            roles = RoleContext.list_roles()

            plan_checks = PlanCheckContext.list_for_env(env.id, 10)

            # Map of policy_uuid → /admin/.../policies?edit=<uuid> for the
            # violation chips. Built once at mount from the union of
            # policies referenced by recent plan_checks; gracefully omits
            # policies that have since been deleted.
            policy_links =
              plan_checks
              |> Enum.flat_map(fn c -> parse_violations(c.violations) end)
              |> Enum.map(& &1["policyId"])
              |> Enum.reject(&is_nil/1)
              |> Enum.uniq()
              |> PolicyContext.get_link_targets_by_uuids()

            socket =
              socket
              |> assign(:project, project)
              |> assign(:workspace, workspace)
              |> assign(:env, env)
              |> assign(:app_url, app_url)
              |> assign(:env_locked, LockContext.is_environment_locked(env.id))
              |> assign(:confirm, nil)
              |> assign(:config_tab, "terraform")
              |> assign(:viewer_perms, viewer_perms)
              |> assign(:show_oidc, false)
              |> assign(:oidc_rules, [])
              |> assign(:oidc_providers, OIDCBackend.list_providers())
              |> assign(:roles, roles)
              |> assign(:show_add_rule, false)
              |> assign(:rule_provider_id, "")
              |> assign(:rule_role_id, default_role_id(roles, "applier"))
              |> assign(:plan_checks, plan_checks)
              |> assign(:policy_links, policy_links)
              |> assign(:policy_gate, PolicyGate.effective(env))
              |> assign(
                :effective_policies_count,
                length(PolicyContext.list_effective_policies_for_env(env.id))
              )
              |> load_units()

            {:ok, socket}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.confirm_dialog :if={@confirm} message={@confirm.message} confirm_event={@confirm.event} confirm_value={@confirm.value} />
    <.nav current_user={@current_user} active="projects" />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header title={@env.name} subtitle={"Environment in #{@project.name}"} />

      <div class="flex items-center justify-between mb-4">
        <nav class="flex items-center gap-2 text-sm text-secondary">
          <a href="/admin/workspaces" class="hover:text-foreground">Workspaces</a>
          <span>/</span>
          <a :if={@workspace} href={"/admin/workspaces/#{@workspace.uuid}"} class="hover:text-foreground">{@workspace.name}</a>
          <span :if={@workspace}>/</span>
          <a href={"/admin/projects/#{@project.uuid}"} class="hover:text-foreground">{@project.name}</a>
          <span>/</span>
          <span class="text-foreground font-medium">{@env.name}</span>
        </nav>
        <div class="flex items-center gap-3">
          <a :if={@current_user.role == "super"} href={"/admin/audit?resource_type=environment&resource_id=#{@env.uuid}&include_children=1"} class="text-xs px-3 py-1.5 rounded-lg border border-border-input text-secondary hover:bg-surface-secondary">
            Audit history
          </a>
          <.button :if={can_manage_oidc_rules?(assigns)} phx-click="show_oidc" variant="secondary" size="sm">OIDC</.button>
          <.link
            :if={RoleContext.has?(@viewer_perms, "policy:manage")}
            navigate={~p"/admin/projects/#{@project.uuid}/environments/#{@env.uuid}/policies"}
            class="text-xs px-3 py-1.5 rounded-lg border border-border-input text-secondary hover:bg-surface-secondary"
          >
            Policies
          </.link>
          <% can_act = if @env_locked, do: RoleContext.has?(@viewer_perms, "state:force_unlock"), else: RoleContext.has?(@viewer_perms, "state:lock") %>
          <span
            class={if can_act, do: "cursor-pointer", else: "cursor-not-allowed opacity-50"}
            title={unless can_act, do: if(@env_locked, do: "Requires the admin role to force-unlock", else: "Requires the planner role to lock"), else: nil}
            phx-click={if can_act, do: "confirm_action"}
            phx-value-event={if @env_locked, do: "env_force_unlock", else: "env_force_lock"}
            phx-value-uuid={@env.uuid}
            phx-value-message={if @env_locked, do: "Unlock all units in this environment?", else: "Lock all units in this environment? This blocks all Terraform operations."}
          >
            <.badge color={if @env_locked, do: "red", else: "green"}>
              {if @env_locked, do: "Environment Locked", else: "Environment Unlocked"}
            </.badge>
          </span>
        </div>
      </div>

      <%!-- OIDC Rules Modal --%>
      <.modal :if={@show_oidc} id="oidc-rules" show on_close="hide_oidc">
        <h3 class="text-lg font-semibold mb-4">OIDC Access Rules — {@env.name}</h3>

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

      <%!-- Backend Config --%>
      <.card class="mb-6">
        <div class="flex items-center justify-between mb-3">
          <div class="flex gap-2">
            <button phx-click="show_terraform_config" class={"text-sm font-semibold px-3 py-1 rounded-lg cursor-pointer " <> if(@config_tab == "terraform", do: "bg-code text-on-primary", else: "text-secondary hover:text-foreground")}>Terraform</button>
            <button phx-click="show_terragrunt_config" class={"text-sm font-semibold px-3 py-1 rounded-lg cursor-pointer " <> if(@config_tab == "terragrunt", do: "bg-code text-on-primary", else: "text-secondary hover:text-foreground")}>Terragrunt</button>
          </div>
          <.copy_button id="copy-backend-config" target="#backend-config-content">Copy</.copy_button>
        </div>
        <div class="bg-code text-on-primary rounded-lg p-4">
          <pre id="backend-config-content" class="text-xs font-mono whitespace-pre-wrap">{if @config_tab == "terraform", do: backend_config(@app_url, @workspace, @project.slug, @env), else: terragrunt_config(@app_url, @workspace, @project.slug, @env)}</pre>
        </div>
      </.card>

      <%!-- Units Table --%>
      <.card>
        <div class="flex items-center justify-between mb-4">
          <h3 class="text-sm font-semibold text-secondary">Units</h3>
          <a href={"/admin/environment/download/#{@env.uuid}"} class="text-sm text-clickable hover:text-clickable-hover">
            Download Root State
          </a>
        </div>
        <.table rows={@units} empty_message="No units yet. State will appear here after your first Terraform apply." row_click={fn unit -> JS.navigate(state_explorer_path(@project, @env, unit.sub_path)) end}>
          <:col :let={unit} label="Path">
            <span class="font-medium text-clickable"><code class="text-xs px-1.5 py-0.5">{if unit.sub_path == "", do: "(root)", else: unit.sub_path}</code></span>
          </:col>
          <:col :let={unit} label="Lock Status">
            <% can_act = if unit.is_locked, do: RoleContext.has?(@viewer_perms, "state:force_unlock"), else: RoleContext.has?(@viewer_perms, "state:lock") %>
            <span
              class={if can_act, do: "cursor-pointer", else: "cursor-not-allowed opacity-50"}
              title={unless can_act, do: if(unit.is_locked, do: "Requires the admin role to force-unlock", else: "Requires the planner role to lock"), else: nil}
              phx-click={if can_act, do: "confirm_action"}
              phx-value-event={if unit.is_locked, do: "unlock_unit", else: "lock_unit"}
              phx-value-uuid={unit.sub_path}
              phx-value-message={if unit.is_locked, do: "Force unlock this unit?", else: "Lock this unit?"}
            >
              <.badge color={if unit.is_locked, do: "red", else: "green"}>
                {if unit.is_locked, do: "Locked", else: "Not Locked"}
              </.badge>
            </span>
          </:col>
          <:col :let={unit} label="State">v{unit.count}</:col>
          <:col :let={unit} label="Last Updated">
            <span class="text-xs text-muted">{Calendar.strftime(unit.latest, "%Y-%m-%d %H:%M")}</span>
          </:col>
          <:action :let={unit}>
            <a href={state_explorer_path(@project, @env, unit.sub_path)} class="text-secondary hover:text-foreground text-xs px-3 py-1.5">
              History
            </a>
            <a href={"/admin/environment/download/#{@env.uuid}?sub_path=#{unit.sub_path}"} class="text-secondary hover:text-foreground text-xs px-3 py-1.5">
              Download
            </a>
          </:action>
        </.table>
      </.card>

      <%!-- Policy Enforcement card (issue #38). Effective state derived
            via `Lynx.Service.PolicyGate.effective/1`. Tri-state selects
            for both gates: inherit / always / never. Banner up top makes
            the current effective state obvious. --%>
      <.card class="mt-6">
        <div class="flex items-center justify-between mb-4">
          <h3 class="text-sm font-semibold text-secondary">Policy Enforcement</h3>
          <.link
            :if={RoleContext.has?(@viewer_perms, "policy:manage")}
            navigate={~p"/admin/projects/#{@project.uuid}/environments/#{@env.uuid}/policies"}
            class="text-xs text-clickable hover:text-clickable-hover"
          >
            Manage policies →
          </.link>
        </div>

        <%!-- Status banner: surfaces effective state without making the user
              read the form. Color cues: red = nothing enforced, green = at
              least one enforcement on. --%>
        <% gate = @policy_gate %>
        <% has_policies = @effective_policies_count > 0 %>
        <% any_enforce = gate.require_passing_plan.value or gate.block_violating_apply.value %>
        <div class={[
          "rounded-lg p-4 mb-4 text-sm",
          cond do
            has_policies and not any_enforce -> "bg-flash-error-bg text-flash-error-text border border-flash-error-border"
            has_policies and any_enforce -> "bg-flash-success-bg text-flash-success-text border border-flash-success-border"
            true -> "bg-inset text-secondary"
          end
        ]}>
          <p class="font-medium">
            {@effective_policies_count} {if @effective_policies_count == 1, do: "policy", else: "policies"} effective for this environment.
          </p>
          <ul class="mt-1 space-y-0.5">
            <li>
              Plan gate: <strong>{if gate.require_passing_plan.value, do: "ON", else: "OFF"}</strong>
              <span class="text-xs">({source_label(gate.require_passing_plan.source)})</span>
            </li>
            <li>
              Block on policy violation: <strong>{if gate.block_violating_apply.value, do: "ON", else: "OFF"}</strong>
              <span class="text-xs">({source_label(gate.block_violating_apply.source)})</span>
            </li>
          </ul>
          <p :if={has_policies and not any_enforce} class="mt-2 text-xs">
            Policies are advisory only — applies will succeed even if a policy fails. Toggle either gate below to enforce.
          </p>

          <%!-- When enforcement IS on, warn that the terraform CLI shows a
                generic "HTTP error: 423" because terraform discards
                response bodies on state-push errors at every log level
                (DEBUG/TRACE/JSON all confirmed). The full reason lands
                in the audit log; deep-link to a pre-filtered view. --%>
          <p :if={has_policies and any_enforce} class="mt-2 text-xs">
            When a policy blocks an apply, terraform shows a generic <code>HTTP error: 423</code> with no further detail (terraform drops the response body).
            The full reason — which policy fired and what it said — is recorded in the
            <.link
              navigate={~p"/admin/audit?action=apply_blocked&resource_type=environment&resource_id=#{@env.uuid}"}
              class="underline hover:no-underline"
            >audit log</.link>.
          </p>
        </div>

        <form
          :if={RoleContext.has?(@viewer_perms, "policy_gate:manage")}
          phx-submit="save_apply_gate"
          class="space-y-3 mb-6"
        >
          <.input
            name="require_passing_plan"
            type="select"
            label="Require a passing plan-check before apply (advanced — requires CI integration)"
            value={tri_state_value(@env.require_passing_plan)}
            options={tri_state_options(:require_passing_plan)}
            hint="Inherit / override for this env. Terraform doesn't call the plan endpoint automatically — CI must `curl POST /tf/.../plan` before `terraform apply`. Worth turning on only when policies need to see plan-level diff info (create / update / delete actions); otherwise the gate below is enough and works with stock terraform."
          />
          <.input
            name="block_violating_apply"
            type="select"
            label="Block apply on policy violation (no plan upload required)"
            value={tri_state_value(@env.block_violating_apply)}
            options={tri_state_options(:block_violating_apply)}
            hint="Inherit / override for this env. Recommended default. Evaluates the new state body against effective policies on every state-write — works with stock terraform / terragrunt, no CI integration needed."
          />
          <.input
            name="plan_max_age_seconds"
            type="number"
            label="Max plan-check age (seconds)"
            value={@env.plan_max_age_seconds}
            hint="A passing plan_check older than this is rejected at apply time."
          />
          <.button type="submit" variant="primary" size="sm">Save Gate Settings</.button>
        </form>

        <h4 class="text-xs font-semibold text-secondary uppercase tracking-wide mb-2">
          Recent plan checks
        </h4>
        <.table rows={@plan_checks} empty_message="No plan checks recorded yet.">
          <:col :let={c} label="When">
            <span class="text-xs text-muted">{Calendar.strftime(c.inserted_at, "%Y-%m-%d %H:%M:%S")}</span>
          </:col>
          <:col :let={c} label="Sub-path">
            <code class="text-xs">{if c.sub_path == "", do: "(root)", else: c.sub_path}</code>
          </:col>
          <:col :let={c} label="Outcome">
            <div>
              <.badge color={plan_check_color(c.outcome)}>{c.outcome}</.badge>
            </div>

            <%!-- For failed / errored plans: show which policies fired
                  and an expandable list of their messages, mirroring the
                  audit-log apply_blocked treatment. --%>
            <div :if={violations = parse_violations(c.violations); violations != []} class="mt-1.5 text-xs space-y-1">
              <div class="flex flex-wrap items-center gap-1">
                <span class="text-muted">policies:</span>
                <%= for v <- violations do %>
                  <% link = Map.get(@policy_links, v["policyId"]) %>
                  <%= if link do %>
                    <.link navigate={link}>
                      <.badge color="purple">{v["policyName"]}</.badge>
                    </.link>
                  <% else %>
                    <.badge color="purple">{v["policyName"]}</.badge>
                  <% end %>
                <% end %>
              </div>
              <details>
                <summary class="text-muted cursor-pointer hover:text-foreground">
                  {length(flat_messages = flatten_violations(violations))} message(s)
                </summary>
                <ul class="bg-inset rounded p-2 mt-1 space-y-1 list-disc ml-5">
                  <li :for={{name, msg} <- flat_messages}>
                    <strong>{name}:</strong> {msg}
                  </li>
                </ul>
              </details>
            </div>
          </:col>
          <:col :let={c} label="Actor">
            <span class="text-xs">{c.actor_name || "—"} <span class="text-muted" title={actor_type_tooltip(c.actor_type)}>({actor_type_label(c.actor_type)})</span></span>
          </:col>
          <:col :let={c} label="Consumed">
            <%= cond do %>
              <% c.consumed_at -> %>
                <span class="text-xs">{Calendar.strftime(c.consumed_at, "%Y-%m-%d %H:%M")}</span>
              <% c.outcome == "passed" -> %>
                <.badge color="blue">available</.badge>
              <% true -> %>
                <span class="text-muted text-xs">n/a</span>
            <% end %>
          </:col>
        </.table>
      </.card>
    </div>
    """
  end

  defp plan_check_color("passed"), do: "green"
  defp plan_check_color("failed"), do: "red"
  defp plan_check_color("errored"), do: "yellow"
  defp plan_check_color(_), do: "gray"

  # plan_check.violations is a JSON-encoded list of `%{policyId, policyName, messages}`
  # from `tf_controller.evaluate_policies/2`. Decode for the env-page renderer
  # so it can show policy chips + the expandable message list.
  defp parse_violations(nil), do: []
  defp parse_violations(""), do: []
  defp parse_violations("[]"), do: []

  defp parse_violations(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp parse_violations(_), do: []

  # Flatten the parsed violations list into [{policy_name, message}, ...]
  # so HEEx can render in a single comprehension (no nested :for support).
  defp flatten_violations(violations) when is_list(violations) do
    Enum.flat_map(violations, fn v ->
      name = v["policyName"] || "unknown"
      Enum.map(v["messages"] || [], &{name, &1})
    end)
  end

  defp flatten_violations(_), do: []

  # Friendly label + tooltip for the actor_type internal jargon
  # (env_secret / oidc / user / system). Mirrors PolicyDetailLive.
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

  # Tri-state UI helpers for the gate selects: nil = inherit, true = on, false = off.
  defp tri_state_value(nil), do: ""
  defp tri_state_value(true), do: "true"
  defp tri_state_value(false), do: "false"

  defp tri_state_options(_key) do
    [
      {"Inherit global default", ""},
      {"Always (override on)", "true"},
      {"Never (override off)", "false"}
    ]
  end

  defp source_label(:explicit), do: "explicit override"
  defp source_label(:inherited), do: "inherited from global default"

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

  def handle_event("show_terraform_config", _, socket),
    do: {:noreply, assign(socket, :config_tab, "terraform")}

  def handle_event("show_terragrunt_config", _, socket),
    do: {:noreply, assign(socket, :config_tab, "terragrunt")}

  def handle_event("env_force_lock", _, socket) do
    with_perm(socket, "state:lock", fn socket ->
      env = socket.assigns.env
      LockContext.force_lock(env.id, socket.assigns.current_user.name)

      AuditContext.log_user(
        socket.assigns.current_user,
        "locked",
        "environment",
        env.uuid,
        env.name
      )

      {:noreply,
       socket
       |> assign(:env_locked, true)
       |> put_flash(:info, "Environment locked")
       |> load_units()}
    end)
  end

  def handle_event("env_force_unlock", _, socket) do
    with_perm(socket, "state:force_unlock", fn socket ->
      env = socket.assigns.env
      LockContext.force_unlock(env.id)

      AuditContext.log_user(
        socket.assigns.current_user,
        "unlocked",
        "environment",
        env.uuid,
        env.name
      )

      {:noreply,
       socket
       |> assign(:env_locked, false)
       |> put_flash(:info, "Environment unlocked")
       |> load_units()}
    end)
  end

  def handle_event("lock_unit", %{"uuid" => sub_path}, socket) do
    with_perm(socket, "state:lock", fn socket ->
      env = socket.assigns.env

      lock =
        LockContext.new_lock(%{
          environment_id: env.id,
          operation: "manual",
          info: "Locked via UI",
          who: socket.assigns.current_user.name,
          version: "",
          path: "",
          sub_path: sub_path,
          uuid: Ecto.UUID.generate(),
          is_active: true
        })

      LockContext.create_lock(lock)
      label = if sub_path == "", do: env.name, else: "#{env.name}/#{sub_path}"
      AuditContext.log_user(socket.assigns.current_user, "locked", "unit", env.uuid, label)
      {:noreply, socket |> put_flash(:info, "Unit locked") |> load_units()}
    end)
  end

  # -- OIDC Rules --
  def handle_event("show_oidc", _, socket) do
    rules = OIDCBackend.list_rules_by_environment(socket.assigns.env.id)

    {:noreply,
     socket
     |> assign(:show_oidc, true)
     |> assign(:oidc_rules, rules)
     |> assign(:show_add_rule, false)}
  end

  def handle_event("hide_oidc", _, socket) do
    {:noreply, socket |> assign(:show_oidc, false) |> assign(:oidc_rules, [])}
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
    role_id = parse_role_id(params["role_id"], socket.assigns.rule_role_id)

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
               environment_id: socket.assigns.env.id,
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

            rules = OIDCBackend.list_rules_by_environment(socket.assigns.env.id)

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
      rules = OIDCBackend.list_rules_by_environment(socket.assigns.env.id)
      {:noreply, socket |> assign(:oidc_rules, rules) |> put_flash(:info, "Rule deleted")}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage OIDC rules")}
    end
  end

  def handle_event("unlock_unit", %{"uuid" => sub_path}, socket) do
    with_perm(socket, "state:force_unlock", fn socket ->
      env = socket.assigns.env

      case LockContext.get_active_lock_by_environment_and_path(env.id, sub_path) do
        nil -> :ok
        lock -> LockContext.update_lock(lock, %{is_active: false})
      end

      label = if sub_path == "", do: env.name, else: "#{env.name}/#{sub_path}"
      AuditContext.log_user(socket.assigns.current_user, "unlocked", "unit", env.uuid, label)
      {:noreply, socket |> put_flash(:info, "Unit unlocked") |> load_units()}
    end)
  end

  def handle_event("save_apply_gate", params, socket) do
    with_perm(socket, "policy_gate:manage", fn socket ->
      attrs = %{
        require_passing_plan: parse_tri_state(params["require_passing_plan"]),
        block_violating_apply: parse_tri_state(params["block_violating_apply"]),
        plan_max_age_seconds: parse_int(params["plan_max_age_seconds"], 1800)
      }

      case EnvironmentContext.update_env(socket.assigns.env, attrs) do
        {:ok, env} ->
          AuditContext.log_user(
            socket.assigns.current_user,
            "updated",
            "environment",
            env.uuid,
            env.name
          )

          {:noreply,
           socket
           |> assign(:env, env)
           |> assign(:policy_gate, PolicyGate.effective(env))
           |> put_flash(:info, "Policy enforcement settings saved.")}

        {:error, changeset} ->
          msg =
            changeset.errors
            |> Enum.map(fn {f, {m, _}} -> "#{f}: #{m}" end)
            |> Enum.join("; ")

          {:noreply, put_flash(socket, :error, msg)}
      end
    end)
  end

  defp parse_tri_state("true"), do: true
  defp parse_tri_state("false"), do: false
  defp parse_tri_state(_), do: nil

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_, default), do: default

  # Server-side permission re-check for destructive event handlers. UI also
  # disables the buttons when the viewer lacks the perm — this is defense in
  # depth for clients that bypass the disabled state (replay, devtools).
  defp with_perm(socket, perm, fun) do
    socket = assign(socket, :confirm, nil)

    if RoleContext.has?(socket.assigns.viewer_perms, perm) do
      fun.(socket)
    else
      {:noreply, put_flash(socket, :error, "You do not have permission for #{perm}")}
    end
  end

  defp load_units(socket) do
    env = socket.assigns.env
    sub_paths = StateContext.list_sub_paths(env.id)

    units =
      Enum.map(sub_paths, fn sp ->
        is_locked =
          LockContext.get_active_lock_by_environment_and_path(env.id, sp.sub_path) != nil

        %{
          sub_path: sp.sub_path,
          count: sp.count,
          latest: sp.latest,
          is_locked: is_locked
        }
      end)

    assign(socket, :units, units)
  end

  defp state_explorer_path(project, env, sub_path) do
    base = "/admin/projects/#{project.uuid}/environments/#{env.uuid}/state"
    if sub_path == "", do: base, else: "#{base}/#{sub_path}"
  end

  defp backend_config(app_url, workspace, project_slug, env) do
    ws_slug = if workspace, do: workspace.slug, else: "default"

    """
    terraform {
      backend "http" {
        username       = "#{env.username}"
        password       = "#{env.secret}"
        address        = "#{app_url}/tf/#{ws_slug}/#{project_slug}/#{env.slug}/state"
        lock_address   = "#{app_url}/tf/#{ws_slug}/#{project_slug}/#{env.slug}/lock"
        unlock_address = "#{app_url}/tf/#{ws_slug}/#{project_slug}/#{env.slug}/unlock"
        lock_method    = "POST"
        unlock_method  = "POST"
      }
    }\
    """
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

  defp can_manage_oidc_rules?(%{current_user: %{role: "super"}}), do: true

  defp can_manage_oidc_rules?(%{viewer_perms: perms}) do
    RoleContext.has?(perms || MapSet.new(), "oidc_rule:manage")
  end

  defp terragrunt_config(app_url, workspace, project_slug, env) do
    ws_slug = if workspace, do: workspace.slug, else: "default"

    """
    # Root terragrunt.hcl
    remote_state {
      backend = "http"

      generate = {
        path      = "backend.tf"
        if_exists = "overwrite_terragrunt"
      }

      config = {
        username       = "#{env.username}"
        password       = "#{env.secret}"
        address        = "#{app_url}/tf/#{ws_slug}/#{project_slug}/#{env.slug}/${path_relative_to_include()}/state"
        lock_address   = "#{app_url}/tf/#{ws_slug}/#{project_slug}/#{env.slug}/${path_relative_to_include()}/lock"
        unlock_address = "#{app_url}/tf/#{ws_slug}/#{project_slug}/#{env.slug}/${path_relative_to_include()}/unlock"
        lock_method    = "POST"
        unlock_method  = "POST"
      }
    }\
    """
  end
end

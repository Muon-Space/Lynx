# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.PolicyController do
  @moduledoc """
  Policy Controller

  REST surface for OPA Rego policies so they can be managed as code
  instead of only through the admin LiveView.

  A policy is attached at exactly one scope. The API expresses that scope
  with UUIDs (`workspace_uuid` / `project_uuid` / `environment_uuid`) and
  resolves them to the internal primary keys server-side, the same way
  `ProjectController` resolves `workspace_id`. Internal integer keys never
  appear in a request or a response.
  """

  use LynxWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Lynx.Context.AuditContext
  alias Lynx.Context.EnvironmentContext
  alias Lynx.Context.PolicyContext
  alias Lynx.Context.ProjectContext
  alias Lynx.Context.RoleContext
  alias Lynx.Context.UserContext
  alias Lynx.Context.WorkspaceContext
  alias Lynx.Model.Policy
  alias Lynx.Service.ValidatorService
  alias LynxWeb.Schemas

  require Logger

  @name_min_length 2
  @name_max_length 100
  @description_max_length 250
  @rego_min_length 1
  @rego_max_length 100_000

  @default_list_limit 10
  @default_list_offset 0

  @manage_permission "policy:manage"

  plug :regular_user when action in [:list, :index, :create, :update, :delete]
  plug :load_and_authorize_policy when action in [:index, :update, :delete]

  tags(["Policies"])
  security([%{"api_key" => []}])

  operation(:list,
    summary: "List policies",
    description:
      "Super users see every policy. Regular users only see policies " <>
        "attached to a project — or to an environment of a project — on " <>
        "which they hold the `policy:manage` permission; global and " <>
        "workspace scopes are super-only and are omitted. Pass at most one " <>
        "scope filter.",
    parameters: [
      limit: [in: :query, type: :integer, description: "Default 10"],
      offset: [in: :query, type: :integer, description: "Default 0"],
      scope: [
        in: :query,
        type: %OpenApiSpex.Schema{type: :string, enum: ["global"]},
        description: "Set to `global` to list only unscoped policies (super only)"
      ],
      workspace_uuid: [in: :query, type: :string, description: "Workspace-scoped only"],
      project_uuid: [in: :query, type: :string, description: "Project-scoped only"],
      environment_uuid: [in: :query, type: :string, description: "Environment-scoped only"]
    ],
    responses: [
      ok: {"Policies", "application/json", Schemas.PolicyList},
      bad_request: {"Validation error", "application/json", Schemas.Error},
      not_found: {"Scope not found", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:create,
    summary: "Create a policy",
    description:
      "Global and workspace scopes are super-only. Project and environment " <>
        "scopes also accept a user holding `policy:manage` on the owning " <>
        "project. The rego source is compile-checked by OPA before it is " <>
        "stored, so a syntax error — or an unreachable OPA — returns 400.",
    request_body: {"Policy", "application/json", Schemas.PolicyCreate},
    responses: [
      created: {"Created", "application/json", Schemas.Policy},
      bad_request: {"Validation error", "application/json", Schemas.Error},
      not_found: {"Scope not found", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:index,
    summary: "Get a policy by UUID",
    parameters: [uuid: [in: :path, required: true, type: :string]],
    responses: [
      ok: {"Policy", "application/json", Schemas.Policy},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:update,
    summary: "Update a policy",
    description:
      "Scope is immutable — moving a policy between scopes would change " <>
        "who is allowed to manage it, so a scope UUID that does not match " <>
        "the policy's current scope returns 400.",
    parameters: [uuid: [in: :path, required: true, type: :string]],
    request_body: {"Policy", "application/json", Schemas.PolicyUpdate},
    responses: [
      ok: {"Policy", "application/json", Schemas.Policy},
      bad_request: {"Validation error", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:delete,
    summary: "Delete a policy",
    description:
      "Nothing holds a foreign key to a policy, so the delete is " <>
        "unconditional. Historic `plan_checks` rows and `apply_blocked` " <>
        "audit events keep the policy UUID they recorded at the time and " <>
        "simply stop resolving to a live policy.",
    parameters: [uuid: [in: :path, required: true, type: :string]],
    responses: [
      no_content: "Policy deleted",
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  defp regular_user(conn, _opts) do
    Logger.info("Validate user permissions")

    if not conn.assigns[:is_logged] do
      Logger.info("User doesn't have the right access permissions")

      conn
      |> put_status(:forbidden)
      |> render(:error, %{message: "Forbidden Access"})
      |> halt
    else
      Logger.info("User has the right access permissions")

      conn
    end
  end

  # `index`, `update` and `delete` all key off the same policy, and the
  # permission answer depends on the policy's scope, so resolve both once
  # here rather than in each action.
  defp load_and_authorize_policy(conn, _opts) do
    uuid = conn.params["uuid"]

    case PolicyContext.get_policy_by_uuid(uuid) do
      nil ->
        conn
        |> put_status(:not_found)
        |> render(:error, %{message: "Policy with ID #{uuid} not found"})
        |> halt

      policy ->
        if can_manage?(conn, scope_of(policy)) do
          assign(conn, :policy, policy)
        else
          Logger.info("User can't manage policy #{uuid}")

          conn
          |> put_status(:forbidden)
          |> render(:error, %{message: "Forbidden Access"})
          |> halt
        end
    end
  end

  @doc """
  List Action Endpoint
  """
  def list(conn, params) do
    # Query params arrive as strings. Every branch below except the
    # unfiltered super one paginates in memory, and `Enum.slice/3` raises
    # on a binary offset or limit, so coerce before use.
    limit = parse_int(params["limit"], @default_list_limit)
    offset = parse_int(params["offset"], @default_list_offset)

    with {:ok, filter} <- list_filter(params),
         {:ok, policies, count} <- list_policies(conn, filter, offset, limit) do
      render(conn, "list.json", %{
        policies: policies,
        metadata: %{
          limit: limit,
          offset: offset,
          totalCount: count
        }
      })
    else
      error -> respond_error(conn, error)
    end
  end

  @doc """
  Create Action Endpoint
  """
  def create(conn, params) do
    with {:ok, _} <- validate_create_request(params),
         {:ok, scope} <- resolve_scope(params),
         :ok <- authorize_scope(conn, scope) do
      attrs =
        PolicyContext.new_policy(%{
          name: params["name"],
          description: params["description"] || "",
          rego_source: params["rego_source"],
          enabled: parse_bool(params["enabled"], true),
          workspace_id: scope.workspace_id,
          project_id: scope.project_id,
          environment_id: scope.environment_id
        })

      case PolicyContext.create_policy(attrs) do
        {:ok, policy} ->
          AuditContext.log(conn, "created", "policy", policy.uuid, policy.name)

          conn
          |> put_status(:created)
          |> render(:index, %{policy: policy})

        {:error, changeset} ->
          conn
          |> put_status(:bad_request)
          |> render(:error, %{message: changeset_error(changeset)})
      end
    else
      error -> respond_error(conn, error)
    end
  end

  @doc """
  Index Action Endpoint
  """
  def index(conn, _params) do
    conn
    |> put_status(:ok)
    |> render(:index, %{policy: conn.assigns.policy})
  end

  @doc """
  Update Action Endpoint
  """
  def update(conn, params) do
    policy = conn.assigns.policy

    with {:ok, _} <- validate_update_request(params),
         :ok <- validate_scope_unchanged(policy, params) do
      attrs = %{
        name: params["name"],
        description: params["description"] || "",
        rego_source: params["rego_source"],
        enabled: parse_bool(params["enabled"], policy.enabled)
      }

      case PolicyContext.update_policy(policy, attrs) do
        {:ok, policy} ->
          AuditContext.log(conn, "updated", "policy", policy.uuid, policy.name)

          conn
          |> put_status(:ok)
          |> render(:index, %{policy: policy})

        {:error, changeset} ->
          conn
          |> put_status(:bad_request)
          |> render(:error, %{message: changeset_error(changeset)})
      end
    else
      error -> respond_error(conn, error)
    end
  end

  @doc """
  Delete Action Endpoint
  """
  def delete(conn, _params) do
    policy = conn.assigns.policy

    Logger.info("Attempt to delete policy with uuid #{policy.uuid}")

    # Unlike a workspace, nothing holds a foreign key to a policy: the
    # scope columns point outwards, `plan_checks.violations` and
    # `audit_events.metadata` only carry the UUID inside a JSON text
    # column, and `PolicyContext.get_link_targets_by_uuids/1` already
    # drops UUIDs with no live row. So there is nothing to guard against
    # and no cascade to warn about.
    case PolicyContext.delete_policy(policy) do
      {:ok, _} ->
        AuditContext.log(conn, "deleted", "policy", policy.uuid, policy.name)

        Logger.info("Policy with uuid #{policy.uuid} is deleted")

        send_resp(conn, :no_content, "")

      {:error, changeset} ->
        conn
        |> put_status(:bad_request)
        |> render(:error, %{message: changeset_error(changeset)})
    end
  end

  # -- Listing --

  defp list_filter(params) do
    selectors =
      [
        {:workspace, params["workspace_uuid"]},
        {:project, params["project_uuid"]},
        {:environment, params["environment_uuid"]}
      ]
      |> Enum.reject(fn {_kind, value} -> blank?(value) end)

    case {params["scope"], selectors} do
      {nil, []} -> {:ok, :any}
      {"", []} -> {:ok, :any}
      {"global", []} -> {:ok, :global}
      {scope, _} when scope not in [nil, "", "global"] -> {:error, :bad_scope_param}
      {_, [selector]} -> {:ok, selector}
      {_, _} -> {:error, :multiple_scopes}
    end
  end

  defp list_policies(conn, :any, offset, limit) do
    if conn.assigns[:is_super] do
      {:ok, PolicyContext.list_policies(offset, limit), PolicyContext.count_policies()}
    else
      paginate(visible_policies(conn), offset, limit)
    end
  end

  defp list_policies(conn, :global, offset, limit) do
    with :ok <- authorize_scope(conn, scope_map()) do
      paginate(PolicyContext.list_policies_global(), offset, limit)
    end
  end

  defp list_policies(conn, {:workspace, uuid}, offset, limit) do
    with {:ok, workspace} <- fetch_workspace(uuid),
         :ok <- authorize_scope(conn, scope_map(workspace_id: workspace.id)) do
      paginate(PolicyContext.list_policies_by_workspace(workspace.id), offset, limit)
    end
  end

  defp list_policies(conn, {:project, uuid}, offset, limit) do
    with {:ok, project} <- fetch_project(uuid),
         :ok <- authorize_scope(conn, scope_map(project_id: project.id, owner: project.id)) do
      paginate(PolicyContext.list_policies_by_project(project.id), offset, limit)
    end
  end

  defp list_policies(conn, {:environment, uuid}, offset, limit) do
    with {:ok, env} <- fetch_environment(uuid),
         :ok <- authorize_scope(conn, scope_map(environment_id: env.id, owner: env.project_id)) do
      paginate(PolicyContext.list_policies_by_environment(env.id), offset, limit)
    end
  end

  defp paginate(policies, offset, limit) do
    {:ok, Enum.slice(policies, offset, limit), length(policies)}
  end

  # Non-super visibility: policies on projects the user can manage
  # policies for, plus policies on those projects' environments. Global
  # and workspace scopes are excluded by construction, matching the
  # super-only rule the LiveViews apply.
  defp visible_policies(conn) do
    case current_user(conn) do
      nil ->
        []

      user ->
        user
        |> RoleContext.list_user_project_access()
        |> Enum.filter(&RoleContext.can?(user, &1.project, @manage_permission))
        |> Enum.map(& &1.project.id)
        |> PolicyContext.list_policies_for_projects()
    end
  end

  # -- Scope resolution --

  # Internal representation of a policy's scope: the FK values to persist
  # plus `owner`, the project whose `policy:manage` grant applies. `owner`
  # is nil for global and workspace scopes, which are super-only.
  defp scope_map(opts \\ []) do
    %{
      workspace_id: Keyword.get(opts, :workspace_id),
      project_id: Keyword.get(opts, :project_id),
      environment_id: Keyword.get(opts, :environment_id),
      owner: Keyword.get(opts, :owner)
    }
  end

  defp scope_of(%Policy{environment_id: id}) when not is_nil(id) do
    owner =
      case EnvironmentContext.get_env_by_id(id) do
        nil -> nil
        env -> env.project_id
      end

    scope_map(environment_id: id, owner: owner)
  end

  defp scope_of(%Policy{project_id: id}) when not is_nil(id),
    do: scope_map(project_id: id, owner: id)

  defp scope_of(%Policy{workspace_id: id}) when not is_nil(id),
    do: scope_map(workspace_id: id)

  defp scope_of(%Policy{}), do: scope_map()

  # The API takes UUIDs; the model stores integer keys. Resolving here
  # keeps the internal keys off the wire in both directions.
  defp resolve_scope(params) do
    selectors =
      [
        {:workspace, params["workspace_uuid"]},
        {:project, params["project_uuid"]},
        {:environment, params["environment_uuid"]}
      ]
      |> Enum.reject(fn {_kind, value} -> blank?(value) end)

    case selectors do
      [] ->
        {:ok, scope_map()}

      [{:workspace, uuid}] ->
        with {:ok, workspace} <- fetch_workspace(uuid),
             do: {:ok, scope_map(workspace_id: workspace.id)}

      [{:project, uuid}] ->
        with {:ok, project} <- fetch_project(uuid),
             do: {:ok, scope_map(project_id: project.id, owner: project.id)}

      [{:environment, uuid}] ->
        with {:ok, env} <- fetch_environment(uuid),
             do: {:ok, scope_map(environment_id: env.id, owner: env.project_id)}

      _multiple ->
        {:error, :multiple_scopes}
    end
  end

  # Moving a policy between scopes changes who may manage it — a project
  # admin could otherwise promote their own policy to global. Reject any
  # scope value that isn't the one the policy already has; repeating the
  # current scope is allowed so a client can PUT back what it GET'd.
  defp validate_scope_unchanged(policy, params) do
    case resolve_scope(params) do
      {:error, reason} ->
        {:error, reason}

      {:ok, requested} ->
        current = scope_of(policy)

        cond do
          scope_ids(requested) == {nil, nil, nil} -> :ok
          scope_ids(requested) == scope_ids(current) -> :ok
          true -> {:error, :scope_immutable}
        end
    end
  end

  defp scope_ids(scope), do: {scope.workspace_id, scope.project_id, scope.environment_id}

  defp fetch_workspace(uuid) do
    with :ok <- check_uuid(uuid, "workspace_uuid") do
      case WorkspaceContext.get_workspace_by_uuid(uuid) do
        nil -> {:error, {:not_found, "Workspace with ID #{uuid} not found"}}
        workspace -> {:ok, workspace}
      end
    end
  end

  defp fetch_project(uuid) do
    with :ok <- check_uuid(uuid, "project_uuid") do
      case ProjectContext.get_project_by_uuid(uuid) do
        nil -> {:error, {:not_found, "Project with ID #{uuid} not found"}}
        project -> {:ok, project}
      end
    end
  end

  defp fetch_environment(uuid) do
    with :ok <- check_uuid(uuid, "environment_uuid") do
      case EnvironmentContext.get_env_by_uuid(uuid) do
        nil -> {:error, {:not_found, "Environment with ID #{uuid} not found"}}
        env -> {:ok, env}
      end
    end
  end

  defp check_uuid(value, field) when is_binary(value) do
    case ValidatorService.is_uuid?(value, "#{field} is invalid") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_uuid(_value, field), do: {:error, "#{field} is invalid"}

  # -- Permissions --

  # Mirrors `PolicyLive.can_manage?/2` and `PolicyDetailLive`: global and
  # workspace scopes have no project to gate on, so they stay super-only;
  # project and environment scopes additionally accept the dedicated
  # `policy:manage` permission on the owning project. Reads use the same
  # rule as writes — rego source is the thing that gates applies, so it is
  # not handed out more widely than the ability to change it.
  defp can_manage?(conn, scope) do
    cond do
      conn.assigns[:is_super] -> true
      is_nil(scope.owner) -> false
      true -> has_manage_permission?(conn, scope.owner)
    end
  end

  defp has_manage_permission?(conn, project_id) do
    case current_user(conn) do
      nil -> false
      user -> RoleContext.can?(user, project_id, @manage_permission)
    end
  end

  defp authorize_scope(conn, scope) do
    if can_manage?(conn, scope), do: :ok, else: {:error, :forbidden}
  end

  defp current_user(conn) do
    case conn.assigns[:user_id] do
      nil -> nil
      id -> UserContext.get_user_by_id(id)
    end
  end

  # -- Error rendering --

  defp respond_error(conn, {:error, :forbidden}) do
    conn
    |> put_status(:forbidden)
    |> render(:error, %{message: "Forbidden Access"})
  end

  defp respond_error(conn, {:error, {:not_found, message}}) do
    conn
    |> put_status(:not_found)
    |> render(:error, %{message: message})
  end

  defp respond_error(conn, {:error, reason}) do
    conn
    |> put_status(:bad_request)
    |> render(:error, %{message: error_message(reason)})
  end

  defp error_message(:multiple_scopes),
    do: "At most one of workspace_uuid, project_uuid or environment_uuid can be set"

  defp error_message(:scope_immutable),
    do: "Policy scope can't be changed. Delete the policy and recreate it at the new scope"

  defp error_message(:bad_scope_param),
    do:
      "scope only accepts `global`. Filter other scopes with workspace_uuid, project_uuid or environment_uuid"

  defp error_message(reason) when is_binary(reason), do: reason

  defp changeset_error(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)
    |> Enum.at(0, "Invalid policy")
  end

  # -- Validation --

  defp validate_create_request(params), do: validate_fields(params, validation_errors())

  defp validate_update_request(params), do: validate_fields(params, validation_errors())

  defp validation_errors do
    %{
      name_required: "Policy name is required",
      name_invalid: "Policy name is invalid",
      description_invalid: "Policy description is invalid",
      rego_required: "Policy rego_source is required",
      rego_invalid: "Policy rego_source is invalid"
    }
  end

  # `description` is optional (the column defaults to ""), so it is only
  # length-checked when present. `rego_source` is checked for presence
  # here; its syntax is compile-checked by OPA inside `PolicyContext`.
  defp validate_fields(params, errs) do
    with {:ok, _} <- ValidatorService.is_string?(params["name"], errs.name_required),
         {:ok, _} <- ValidatorService.is_not_empty?(params["name"], errs.name_invalid),
         {:ok, _} <-
           ValidatorService.is_length_between?(
             params["name"],
             @name_min_length,
             @name_max_length,
             errs.name_invalid
           ),
         {:ok, _} <- ValidatorService.is_string?(params["rego_source"], errs.rego_required),
         {:ok, _} <- ValidatorService.is_not_empty?(params["rego_source"], errs.rego_invalid),
         {:ok, _} <-
           ValidatorService.is_length_between?(
             params["rego_source"],
             @rego_min_length,
             @rego_max_length,
             errs.rego_invalid
           ),
         {:ok, _} <- validate_description(params["description"], errs) do
      {:ok, ""}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_description(nil, _errs), do: {:ok, ""}
  defp validate_description("", _errs), do: {:ok, ""}

  defp validate_description(description, errs) do
    with {:ok, _} <- ValidatorService.is_string?(description, errs.description_invalid) do
      ValidatorService.is_length_between?(
        description,
        1,
        @description_max_length,
        errs.description_invalid
      )
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp parse_bool(nil, default), do: default
  defp parse_bool(value, _default) when value in [true, "true"], do: true
  defp parse_bool(value, _default) when value in [false, "false"], do: false
  defp parse_bool(_value, default), do: default

  # Query params are strings; internal callers pass integers. Mirrors the
  # helper in AuditController and WorkspaceController.
  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(val, _) when is_integer(val), do: val
end

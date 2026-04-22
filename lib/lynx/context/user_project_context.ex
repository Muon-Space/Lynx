defmodule Lynx.Context.UserProjectContext do
  @moduledoc """
  UserProject Context — direct (non-team) role grants from a user to a project.
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.UserProject

  def new_user_project(attrs \\ %{}) do
    %{
      user_id: attrs.user_id,
      project_id: attrs.project_id,
      role_id: attrs.role_id,
      uuid: Map.get(attrs, :uuid, Ecto.UUID.generate())
    }
  end

  def create_user_project(attrs \\ %{}) do
    %UserProject{}
    |> UserProject.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Upsert: if (user_id, project_id, environment_id) already exists, replace
  the role_id. Returns `{:ok, user_project}` on success.

  `expires_at` — optional `DateTime`, `nil` = permanent.
  `environment_id` — optional, `nil` = project-wide grant; an integer scopes
  the grant to a single env (per-env override).
  """
  def assign_role(user_id, project_id, role_id, expires_at \\ nil, environment_id \\ nil) do
    case get_by_user_and_project(user_id, project_id, environment_id) do
      nil ->
        attrs =
          %{
            user_id: user_id,
            project_id: project_id,
            role_id: role_id,
            environment_id: environment_id,
            uuid: Ecto.UUID.generate()
          }
          |> maybe_put_expires_at(expires_at)

        create_user_project(attrs)

      existing ->
        existing
        |> UserProject.changeset(%{role_id: role_id, expires_at: expires_at})
        |> Repo.update()
    end
  end

  defp maybe_put_expires_at(attrs, nil), do: attrs
  defp maybe_put_expires_at(attrs, %DateTime{} = dt), do: Map.put(attrs, :expires_at, dt)

  @doc """
  Update only the role for an existing grant — preserves `expires_at`.
  Use this from in-place role-change events so toggling a role doesn't
  inadvertently clear an admin-set expiry.
  """
  def set_role(user_id, project_id, role_id, environment_id \\ nil) do
    base =
      from(up in UserProject,
        where: up.user_id == ^user_id and up.project_id == ^project_id
      )

    base
    |> scope_to_env(environment_id)
    |> Repo.update_all(set: [role_id: role_id, updated_at: DateTime.utc_now()])
  end

  @doc "Set or clear the expiry on an existing grant."
  def set_expires_at(user_id, project_id, expires_at, environment_id \\ nil) do
    case get_by_user_and_project(user_id, project_id, environment_id) do
      nil ->
        {:error, :not_found}

      existing ->
        existing
        |> UserProject.changeset(%{expires_at: expires_at})
        |> Repo.update()
    end
  end

  def get_by_user_and_project(user_id, project_id, environment_id \\ nil) do
    base =
      from(up in UserProject,
        where: up.user_id == ^user_id and up.project_id == ^project_id
      )

    base
    |> scope_to_env(environment_id)
    |> limit(1)
    |> Repo.one()
  end

  def get_role_id_for(user_id, project_id, environment_id \\ nil) do
    base =
      from(up in UserProject,
        where: up.user_id == ^user_id and up.project_id == ^project_id,
        select: up.role_id
      )

    base
    |> scope_to_env(environment_id)
    |> Repo.one()
  end

  def list_for_project(project_id, environment_id \\ nil) do
    base =
      from(up in UserProject,
        where: up.project_id == ^project_id,
        order_by: [asc: up.inserted_at]
      )

    base
    |> scope_to_env(environment_id)
    |> Repo.all()
  end

  @doc """
  List `{user, user_project_row}` pairs for rendering the Access card.
  Defaults to project-wide grants; pass `environment_id` for env overrides.
  """
  def list_user_assignments_for_project(project_id, environment_id \\ nil) do
    alias Lynx.Model.User

    base =
      from(up in UserProject,
        join: u in User,
        on: u.id == up.user_id,
        where: up.project_id == ^project_id,
        order_by: [asc: u.email],
        select: {u, up}
      )

    base
    |> scope_to_env_user_project(environment_id)
    |> Repo.all()
  end

  def list_for_user(user_id) do
    from(up in UserProject, where: up.user_id == ^user_id)
    |> Repo.all()
  end

  def delete_user_project(user_project), do: Repo.delete(user_project)

  def remove(user_id, project_id, environment_id \\ nil) do
    base =
      from(up in UserProject,
        where: up.user_id == ^user_id and up.project_id == ^project_id
      )

    base
    |> scope_to_env(environment_id)
    |> Repo.delete_all()
  end

  defp scope_to_env(query, nil), do: from(up in query, where: is_nil(up.environment_id))

  defp scope_to_env(query, env_id) when is_integer(env_id),
    do: from(up in query, where: up.environment_id == ^env_id)

  defp scope_to_env_user_project(query, nil),
    do: from([up, _u] in query, where: is_nil(up.environment_id))

  defp scope_to_env_user_project(query, env_id) when is_integer(env_id),
    do: from([up, _u] in query, where: up.environment_id == ^env_id)
end

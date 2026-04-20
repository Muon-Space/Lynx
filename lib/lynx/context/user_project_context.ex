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
  Upsert: if (user_id, project_id) already exists, replace the role_id.
  Returns {:ok, user_project} on success.
  """
  def assign_role(user_id, project_id, role_id) do
    case get_by_user_and_project(user_id, project_id) do
      nil ->
        create_user_project(%{
          user_id: user_id,
          project_id: project_id,
          role_id: role_id,
          uuid: Ecto.UUID.generate()
        })

      existing ->
        existing
        |> UserProject.changeset(%{role_id: role_id})
        |> Repo.update()
    end
  end

  def get_by_user_and_project(user_id, project_id) do
    from(up in UserProject,
      where: up.user_id == ^user_id and up.project_id == ^project_id
    )
    |> limit(1)
    |> Repo.one()
  end

  def get_role_id_for(user_id, project_id) do
    from(up in UserProject,
      where: up.user_id == ^user_id and up.project_id == ^project_id,
      select: up.role_id
    )
    |> Repo.one()
  end

  def list_for_project(project_id) do
    from(up in UserProject,
      where: up.project_id == ^project_id,
      order_by: [asc: up.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  List `{user, user_project_row}` pairs for rendering the Access card.
  """
  def list_user_assignments_for_project(project_id) do
    alias Lynx.Model.User

    from(up in UserProject,
      join: u in User,
      on: u.id == up.user_id,
      where: up.project_id == ^project_id,
      order_by: [asc: u.email],
      select: {u, up}
    )
    |> Repo.all()
  end

  def list_for_user(user_id) do
    from(up in UserProject, where: up.user_id == ^user_id)
    |> Repo.all()
  end

  def delete_user_project(user_project), do: Repo.delete(user_project)

  def remove(user_id, project_id) do
    from(up in UserProject,
      where: up.user_id == ^user_id and up.project_id == ^project_id
    )
    |> Repo.delete_all()
  end
end

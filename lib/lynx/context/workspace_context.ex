defmodule Lynx.Context.WorkspaceContext do
  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.Workspace

  def new_workspace(attrs \\ %{}) do
    %{
      name: attrs.name,
      slug: attrs.slug,
      description: attrs[:description] || "",
      uuid: Map.get(attrs, :uuid, Ecto.UUID.generate())
    }
  end

  def create_workspace(attrs \\ %{}) do
    %Workspace{}
    |> Workspace.changeset(attrs)
    |> Repo.insert()
  end

  def get_workspace_by_id(id), do: Repo.get(Workspace, id)

  def get_workspace_by_uuid(uuid) do
    from(w in Workspace, where: w.uuid == ^uuid)
    |> Repo.one()
  end

  def get_workspace_by_slug(nil), do: nil
  def get_workspace_by_slug(""), do: nil

  def get_workspace_by_slug(slug) do
    from(w in Workspace, where: w.slug == ^slug)
    |> Repo.one()
  end

  def get_workspaces(offset, limit) do
    from(w in Workspace, order_by: [asc: w.name], limit: ^limit, offset: ^offset)
    |> Repo.all()
  end

  def count_workspaces do
    from(w in Workspace, select: count(w.id))
    |> Repo.one()
  end

  def update_workspace(workspace, attrs) do
    workspace
    |> Workspace.changeset(attrs)
    |> Repo.update()
  end

  def delete_workspace(workspace), do: Repo.delete(workspace)
end

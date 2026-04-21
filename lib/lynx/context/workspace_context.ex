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

  @doc """
  Search workspaces by name or slug substring (case-insensitive). For
  autocomplete inputs that need server-side search instead of eager-loading.
  Returns at most `limit` matches ordered by name.
  """
  def search_workspaces(query, limit \\ 25) when is_binary(query) do
    pattern = "%#{escape_like(query)}%"

    from(w in Workspace,
      where: ilike(w.name, ^pattern) or ilike(w.slug, ^pattern),
      order_by: [asc: w.name],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp escape_like(query),
    do:
      query
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

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

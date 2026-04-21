defmodule Lynx.Context.SearchTest do
  @moduledoc """
  Covers the autocomplete-substrate search functions used by `<.combobox>`:

    * `WorkspaceContext.search_workspaces/2`
    * `ProjectContext.search_projects/2` and `search_projects_for_user/3`
    * `TeamContext.search_user_teams/3`

  `UserContext.search_users/2` and `TeamContext.search_teams/2` predate this PR
  and have no scoping nuance to test beyond the same patterns covered here.
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.{ProjectContext, TeamContext, UserContext, WorkspaceContext}

  setup do
    mark_installed()
    :ok
  end

  describe "search_workspaces/2" do
    test "returns workspaces matching name (case-insensitive)" do
      _ = create_workspace(%{name: "Production AWS", slug: "prod-aws"})
      _ = create_workspace(%{name: "staging-gcp", slug: "stg-gcp"})

      results = WorkspaceContext.search_workspaces("prod")

      assert Enum.any?(results, &(&1.name == "Production AWS"))
      refute Enum.any?(results, &(&1.name == "staging-gcp"))
    end

    test "matches on slug too" do
      _ = create_workspace(%{name: "Apple", slug: "fruit-apple"})
      results = WorkspaceContext.search_workspaces("fruit")
      assert Enum.any?(results, &(&1.slug == "fruit-apple"))
    end

    test "empty query returns workspaces (capped by :limit)" do
      _ = create_workspace(%{name: "A", slug: "a-ws"})
      _ = create_workspace(%{name: "B", slug: "b-ws"})

      assert length(WorkspaceContext.search_workspaces("")) >= 2
    end

    test "escapes LIKE-special characters" do
      _ = create_workspace(%{name: "Plain", slug: "plain"})
      _ = create_workspace(%{name: "Has 100% Coverage", slug: "has-pct"})

      results = WorkspaceContext.search_workspaces("100%")

      # Without escaping, % would be a wildcard and match every row.
      assert length(results) == 1
      assert hd(results).name == "Has 100% Coverage"
    end

    test "respects :limit" do
      for i <- 1..6, do: create_workspace(%{name: "Bulk #{i}", slug: "bulk-#{i}"})
      assert length(WorkspaceContext.search_workspaces("Bulk", 3)) == 3
    end
  end

  describe "search_projects/2" do
    test "matches on name and slug, ordered by name" do
      ws = create_workspace()
      _ = create_project(%{name: "Beta", slug: "beta", workspace_id: ws.id})
      _ = create_project(%{name: "Alpha Service", slug: "alpha-svc", workspace_id: ws.id})

      results = ProjectContext.search_projects("alpha")
      assert hd(results).slug == "alpha-svc"
    end

    test "escapes LIKE-special characters" do
      ws = create_workspace()
      _ = create_project(%{name: "first", slug: "first", workspace_id: ws.id})
      _ = create_project(%{name: "raw_path", slug: "raw_path", workspace_id: ws.id})

      results = ProjectContext.search_projects("raw_path")
      # Without escaping, "_" matches any single char so "first" would also match.
      assert length(results) == 1
    end
  end

  describe "search_projects_for_user/3" do
    test "returns only projects whose teams the user belongs to" do
      ws = create_workspace()
      mine = create_project(%{name: "Mine", slug: "mine", workspace_id: ws.id})
      _theirs = create_project(%{name: "Theirs", slug: "theirs", workspace_id: ws.id})

      user = create_user()

      {:ok, team} =
        TeamContext.create_team(
          TeamContext.new_team(%{
            name: "T",
            slug: "t-#{System.unique_integer([:positive])}",
            description: "test"
          })
        )

      {:ok, _} = UserContext.add_user_to_team(user.id, team.id)
      {:ok, _} = ProjectContext.add_project_to_team(mine.id, team.id)

      results = ProjectContext.search_projects_for_user(user.id, "")

      assert Enum.any?(results, &(&1.id == mine.id))
      refute Enum.any?(results, &(&1.name == "Theirs"))
    end

    test "user with no teams sees nothing" do
      ws = create_workspace()
      _ = create_project(%{name: "Public", slug: "public", workspace_id: ws.id})

      lonely = create_user()
      assert ProjectContext.search_projects_for_user(lonely.id, "") == []
    end
  end

  describe "search_user_teams/3" do
    test "returns only teams the user belongs to, filtered by query" do
      user = create_user()

      {:ok, mine} =
        TeamContext.create_team(
          TeamContext.new_team(%{
            name: "Platform",
            slug: "platform",
            description: "test"
          })
        )

      {:ok, _theirs} =
        TeamContext.create_team(
          TeamContext.new_team(%{
            name: "Marketing",
            slug: "marketing",
            description: "test"
          })
        )

      {:ok, _} = UserContext.add_user_to_team(user.id, mine.id)

      assert TeamContext.search_user_teams(user.id, "") |> Enum.map(& &1.id) == [mine.id]
      assert TeamContext.search_user_teams(user.id, "plat") |> length() == 1
      assert TeamContext.search_user_teams(user.id, "market") == []
    end
  end
end

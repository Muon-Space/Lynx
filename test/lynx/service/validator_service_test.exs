defmodule Lynx.Service.ValidatorServiceTest do
  @moduledoc """
  Validator Service Test Cases
  """
  use Lynx.DataCase

  alias Lynx.Service.ValidatorService

  alias Lynx.Context.{
    EnvironmentContext,
    ProjectContext,
    TeamContext,
    UserContext,
    WorkspaceContext
  }

  describe "is_number?/2" do
    test "accepts integers and floats" do
      assert ValidatorService.is_number?(1, "err") == {:ok, 1}
      assert ValidatorService.is_number?(1.5, "err") == {:ok, 1.5}
    end

    test "rejects non-numbers" do
      assert ValidatorService.is_number?("1", "err") == {:error, "err"}
      assert ValidatorService.is_number?(nil, "err") == {:error, "err"}
    end
  end

  describe "is_integer?/2" do
    test "accepts integers" do
      assert ValidatorService.is_integer?(42, "err") == {:ok, 42}
    end

    test "rejects floats and strings" do
      assert ValidatorService.is_integer?(1.5, "err") == {:error, "err"}
      assert ValidatorService.is_integer?("1", "err") == {:error, "err"}
    end
  end

  describe "is_float?/2" do
    test "accepts floats" do
      assert ValidatorService.is_float?(1.5, "err") == {:ok, 1.5}
    end

    test "rejects integers and strings" do
      assert ValidatorService.is_float?(1, "err") == {:error, "err"}
      assert ValidatorService.is_float?("1.5", "err") == {:error, "err"}
    end
  end

  describe "is_string?/2" do
    test "accepts binaries" do
      assert ValidatorService.is_string?("hello", "err") == {:ok, "hello"}
    end

    test "rejects atoms, numbers, lists" do
      assert ValidatorService.is_string?(:hello, "err") == {:error, "err"}
      assert ValidatorService.is_string?(42, "err") == {:error, "err"}
      assert ValidatorService.is_string?([], "err") == {:error, "err"}
    end
  end

  describe "is_list?/2" do
    test "accepts lists" do
      assert ValidatorService.is_list?([1, 2], "err") == {:ok, [1, 2]}
      assert ValidatorService.is_list?([], "err") == {:ok, []}
    end

    test "rejects non-lists" do
      assert ValidatorService.is_list?("hi", "err") == {:error, "err"}
      assert ValidatorService.is_list?(%{}, "err") == {:error, "err"}
    end
  end

  describe "is_not_empty_list?/2" do
    test "accepts non-empty lists" do
      assert ValidatorService.is_not_empty_list?([1], "err") == {:ok, [1]}
    end

    test "rejects empty list" do
      assert ValidatorService.is_not_empty_list?([], "err") == {:error, "err"}
    end
  end

  describe "in?/3" do
    test "accepts when value is in list" do
      assert ValidatorService.in?("a", ["a", "b"], "err") == {:ok, "a"}
    end

    test "rejects when value is missing" do
      assert ValidatorService.in?("c", ["a", "b"], "err") == {:error, "err"}
    end
  end

  describe "not_in?/3" do
    test "accepts when value not in list" do
      assert ValidatorService.not_in?("c", ["a", "b"], "err") == {:ok, "c"}
    end

    test "rejects when value is in list" do
      assert ValidatorService.not_in?("a", ["a", "b"], "err") == {:error, "err"}
    end
  end

  describe "is_not_empty?/2" do
    test "rejects nil and empty string" do
      assert ValidatorService.is_not_empty?(nil, "err") == {:error, "err"}
      assert ValidatorService.is_not_empty?("", "err") == {:error, "err"}
    end

    test "accepts non-empty values" do
      assert ValidatorService.is_not_empty?("hi", "err") == {:ok, "hi"}
      assert ValidatorService.is_not_empty?(0, "err") == {:ok, 0}
    end
  end

  describe "is_uuid?/2" do
    test "accepts valid UUIDs" do
      uuid = Ecto.UUID.generate()
      assert ValidatorService.is_uuid?(uuid, "err") == {:ok, uuid}
    end

    test "rejects malformed UUIDs" do
      assert ValidatorService.is_uuid?("not-a-uuid", "err") == {:error, "err"}
      assert ValidatorService.is_uuid?("", "err") == {:error, "err"}
      # Almost-correct UUIDs (wrong length / wrong chars)
      assert ValidatorService.is_uuid?("00000000-0000-0000-0000-00000000", "err") ==
               {:error, "err"}

      assert ValidatorService.is_uuid?("ZZZZZZZZ-0000-0000-0000-000000000000", "err") ==
               {:error, "err"}
    end
  end

  describe "is_url?/2" do
    test "accepts URLs with scheme + host" do
      assert ValidatorService.is_url?("https://example.com", "err") ==
               {:ok, "https://example.com"}

      assert ValidatorService.is_url?("http://localhost:4000/path", "err") ==
               {:ok, "http://localhost:4000/path"}
    end

    test "rejects strings missing scheme" do
      assert ValidatorService.is_url?("example.com", "err") == {:error, "err"}
      assert ValidatorService.is_url?("/just/a/path", "err") == {:error, "err"}
      # NOTE: validator is loose — "https://" (empty host string) passes,
      # because URI.parse returns host: "" (not nil). Documenting current
      # behavior; tighten the validator if stricter URL checking is needed.
    end
  end

  describe "is_email?/2" do
    test "accepts well-formed emails" do
      assert ValidatorService.is_email?("a@b.co", "err") == {:ok, "a@b.co"}

      assert ValidatorService.is_email?("user.name+tag@example.com", "err") ==
               {:ok, "user.name+tag@example.com"}
    end

    test "rejects malformed emails" do
      assert ValidatorService.is_email?("notanemail", "err") == {:error, "err"}
      assert ValidatorService.is_email?("a@", "err") == {:error, "err"}
      assert ValidatorService.is_email?("@b.co", "err") == {:error, "err"}
      assert ValidatorService.is_email?("a@b", "err") == {:error, "err"}
    end
  end

  describe "is_password?/2" do
    test "accepts passwords with at least one non-digit and 6-32 chars" do
      assert ValidatorService.is_password?("hello1", "err") == {:ok, "hello1"}

      assert ValidatorService.is_password?(String.duplicate("a", 32), "err") ==
               {:ok, String.duplicate("a", 32)}
    end

    test "rejects too-short, too-long, all-digit, or whitespace-containing", %{} do
      assert ValidatorService.is_password?("abc", "err") == {:error, "err"}
      assert ValidatorService.is_password?(String.duplicate("a", 33), "err") == {:error, "err"}
      assert ValidatorService.is_password?("123456", "err") == {:error, "err"}
      assert ValidatorService.is_password?("hello world", "err") == {:error, "err"}
    end
  end

  describe "is_length_between?/4" do
    test "accepts strings within range" do
      assert ValidatorService.is_length_between?("ab", 2, 5, "err") == {:ok, "ab"}
      assert ValidatorService.is_length_between?("abcde", 2, 5, "err") == {:ok, "abcde"}
    end

    test "rejects too short or too long" do
      assert ValidatorService.is_length_between?("a", 2, 5, "err") == {:error, "err"}
      assert ValidatorService.is_length_between?("abcdef", 2, 5, "err") == {:error, "err"}
    end
  end

  describe "is_email_used?/3 (DB-backed)" do
    test "returns {:ok, email} when email not in use" do
      assert ValidatorService.is_email_used?("free@example.com", nil, "err") ==
               {:ok, "free@example.com"}
    end

    test "returns {:error, err} when email is taken by a different user" do
      {:ok, user} =
        UserContext.create_user(
          UserContext.new_user(%{
            email: "taken@example.com",
            name: "Test User",
            password_hash: "$2b$12$" <> String.duplicate("a", 53),
            verified: true,
            last_seen: DateTime.utc_now() |> DateTime.truncate(:second),
            role: "user",
            api_key: "test-api-key-#{System.unique_integer([:positive])}",
            uuid: Ecto.UUID.generate()
          })
        )

      # No user_uuid passed → any existing user means "taken"
      assert ValidatorService.is_email_used?("taken@example.com", nil, "err") == {:error, "err"}

      # Different user_uuid → still "taken"
      other_uuid = Ecto.UUID.generate()

      assert ValidatorService.is_email_used?("taken@example.com", other_uuid, "err") ==
               {:error, "err"}

      # Same user editing their own profile → "ok"
      assert ValidatorService.is_email_used?("taken@example.com", user.uuid, "err") ==
               {:ok, "taken@example.com"}
    end
  end

  describe "is_team_slug_used?/3 (DB-backed)" do
    test "returns {:ok, slug} when not used" do
      assert ValidatorService.is_team_slug_used?("never-used", nil, "err") ==
               {:ok, "never-used"}
    end

    test "returns {:error, err} when used by another team, ok when same uuid" do
      {:ok, team} = create_team(%{slug: "platform"})

      assert ValidatorService.is_team_slug_used?("platform", nil, "err") == {:error, "err"}

      assert ValidatorService.is_team_slug_used?("platform", Ecto.UUID.generate(), "err") ==
               {:error, "err"}

      assert ValidatorService.is_team_slug_used?("platform", team.uuid, "err") ==
               {:ok, "platform"}
    end
  end

  describe "is_project_slug_used?/4 (DB-backed)" do
    test "raises when team uuid is unknown" do
      bad_uuid = Ecto.UUID.generate()

      assert_raise Lynx.Exception.InvalidRequest, fn ->
        ValidatorService.is_project_slug_used?("any-slug", bad_uuid, nil, "err")
      end
    end

    test "returns {:ok, slug} when slug not used in team's projects" do
      {:ok, team} = create_team(%{slug: "team-a"})

      assert ValidatorService.is_project_slug_used?("new-proj", team.uuid, nil, "err") ==
               {:ok, "new-proj"}
    end

    test "returns {:error, err} when slug used by other project; ok when same uuid" do
      {:ok, team} = create_team(%{slug: "team-b"})
      ws = create_workspace()

      project_uuid = Ecto.UUID.generate()

      {:ok, project} =
        ProjectContext.create_project(
          ProjectContext.new_project(%{
            name: "P",
            slug: "shared-slug",
            description: "x",
            workspace_id: ws.id,
            uuid: project_uuid
          })
        )

      # Link the team to the project so the slug check finds it
      ProjectContext.add_project_to_team(project.id, team.id)

      assert ValidatorService.is_project_slug_used?("shared-slug", team.uuid, nil, "err") ==
               {:error, "err"}

      assert ValidatorService.is_project_slug_used?(
               "shared-slug",
               team.uuid,
               Ecto.UUID.generate(),
               "err"
             ) == {:error, "err"}

      assert ValidatorService.is_project_slug_used?("shared-slug", team.uuid, project.uuid, "err") ==
               {:ok, "shared-slug"}
    end
  end

  describe "is_environment_slug_used?/4 (DB-backed)" do
    test "raises when project uuid is unknown" do
      bad_uuid = Ecto.UUID.generate()

      assert_raise Lynx.Exception.InvalidRequest, fn ->
        ValidatorService.is_environment_slug_used?("any-slug", bad_uuid, nil, "err")
      end
    end

    test "returns {:ok, slug} when slug not used" do
      {project, _env} = create_project_with_env()

      assert ValidatorService.is_environment_slug_used?("new-env", project.uuid, nil, "err") ==
               {:ok, "new-env"}
    end

    test "returns {:error, err} when slug used by another env; ok when same uuid" do
      {project, env} = create_project_with_env()

      assert ValidatorService.is_environment_slug_used?(env.slug, project.uuid, nil, "err") ==
               {:error, "err"}

      assert ValidatorService.is_environment_slug_used?(
               env.slug,
               project.uuid,
               Ecto.UUID.generate(),
               "err"
             ) == {:error, "err"}

      assert ValidatorService.is_environment_slug_used?(
               env.slug,
               project.uuid,
               env.uuid,
               "err"
             ) == {:ok, env.slug}
    end
  end

  # Helpers

  defp create_team(attrs) do
    n = System.unique_integer([:positive])

    defaults = %{
      name: "Team #{n}",
      slug: "team-#{n}",
      description: "test team"
    }

    defaults
    |> Map.merge(attrs)
    |> TeamContext.new_team()
    |> TeamContext.create_team()
  end

  defp create_workspace do
    n = System.unique_integer([:positive])

    {:ok, ws} =
      WorkspaceContext.create_workspace(
        WorkspaceContext.new_workspace(%{
          name: "WS #{n}",
          slug: "ws-#{n}",
          description: "test"
        })
      )

    ws
  end

  defp create_project_with_env do
    ws = create_workspace()
    n = System.unique_integer([:positive])

    {:ok, project} =
      ProjectContext.create_project(
        ProjectContext.new_project(%{
          name: "P #{n}",
          slug: "p-#{n}",
          description: "test",
          workspace_id: ws.id
        })
      )

    {:ok, env} =
      EnvironmentContext.create_env(
        EnvironmentContext.new_env(%{
          name: "Env",
          slug: "env-#{n}",
          username: "u",
          secret: "s",
          project_id: project.id
        })
      )

    {project, env}
  end
end

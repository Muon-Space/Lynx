defmodule Lynx.Context.StateContextSearchTest do
  @moduledoc """
  Postgres tsvector search across state files (issue #37).

  Covers:
    * Match / no-match / empty-query cases
    * Latest-version-only semantics — older version with the term doesn't
      surface if the latest version no longer contains it
    * RBAC scoping — regular users only see results for envs they have
      `state:read` on; super sees every workspace
    * Cross-env scoping — a project-wide grant on project A doesn't leak
      project B's results
    * Special chars in the user query don't break parsing (ts_query is
      escape-safe via plainto_tsquery, so this is a regression guard, not
      a defense-in-depth assertion)
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.{RoleContext, StateContext, UserProjectContext}

  setup do
    mark_installed()

    # Two workspaces / projects / envs so RBAC scoping has somewhere to
    # leak from. Each env gets one matching state.
    ws_a = create_workspace(%{name: "WS A", slug: "ws-a"})
    ws_b = create_workspace(%{name: "WS B", slug: "ws-b"})

    project_a = create_project(%{workspace_id: ws_a.id, name: "Proj A", slug: "proj-a"})
    project_b = create_project(%{workspace_id: ws_b.id, name: "Proj B", slug: "proj-b"})

    env_a = create_env(project_a, %{name: "prod", slug: "prod"})
    env_b = create_env(project_b, %{name: "prod", slug: "prod"})

    create_state(env_a, %{
      value: ~s({"resources":[{"type":"aws_iam_role","name":"deploy_bot"}]})
    })

    create_state(env_b, %{
      value: ~s({"resources":[{"type":"aws_s3_bucket","name":"backups"}]})
    })

    {:ok,
     ws_a: ws_a,
     ws_b: ws_b,
     project_a: project_a,
     project_b: project_b,
     env_a: env_a,
     env_b: env_b}
  end

  describe "search_states_for_user/3 — finding" do
    test "super finds matches across every workspace" do
      super_user = create_super()
      results = StateContext.search_states_for_user("deploy_bot", super_user)

      assert [%{environment: %{name: "prod"}, project: %{name: "Proj A"}, snippet: snippet}] =
               results

      # Postgres' 'simple' config tokenizes on non-alphanumerics, so
      # `deploy_bot` becomes two tokens; both end up wrapped in marker
      # tags inside the snippet (with the `_` kept as plain text between).
      # Asserting on each token + a marker proves the match + highlight
      # without coupling to exact spacing.
      assert snippet =~ "deploy"
      assert snippet =~ "bot"
      assert snippet =~ "⟦MARK⟧"
    end

    test "snippet wraps matched terms with the configured markers" do
      super_user = create_super()
      [%{snippet: snippet}] = StateContext.search_states_for_user("deploy_bot", super_user)

      # Markers must be present + balanced. The LV strips them and re-wraps
      # with <mark> tags after escaping the rest of the snippet.
      assert snippet =~ "⟦MARK⟧"
      assert snippet =~ "⟦/MARK⟧"
    end

    test "returns workspace + project + env breadcrumb data" do
      super_user = create_super()
      [hit] = StateContext.search_states_for_user("deploy_bot", super_user)

      assert hit.workspace.slug == "ws-a"
      assert hit.project.slug == "proj-a"
      assert hit.environment.slug == "prod"
      assert hit.sub_path == ""
      assert is_binary(hit.state_uuid)
      assert is_float(hit.rank)
    end

    test "no match returns empty list" do
      super_user = create_super()
      assert StateContext.search_states_for_user("nonexistent_resource_xyz", super_user) == []
    end

    test "empty / whitespace query short-circuits to no DB call" do
      super_user = create_super()
      assert StateContext.search_states_for_user("", super_user) == []
      assert StateContext.search_states_for_user("   ", super_user) == []
    end

    test "special chars in query don't crash plainto_tsquery", %{env_a: env_a} do
      create_state(env_a, %{value: ~s({"weird":"100% off"})})
      super_user = create_super()
      # Punctuation-only query yields no terms → no rows; mustn't raise.
      assert StateContext.search_states_for_user("'; DROP TABLE states; --", super_user) == []
      assert StateContext.search_states_for_user("100%", super_user) |> length() >= 0
    end
  end

  describe "search_states_for_user/3 — latest version only" do
    test "older version that matches is hidden when latest no longer matches", %{env_a: env_a} do
      # env_a's setup state contains deploy_bot. Push a newer version that
      # *removes* it — search for deploy_bot must return zero, not one.
      create_state(env_a, %{
        value: ~s({"resources":[{"type":"aws_iam_role","name":"renamed_role"}]})
      })

      super_user = create_super()
      results = StateContext.search_states_for_user("deploy_bot", super_user)

      assert results == []
    end

    test "latest version that matches surfaces once even with many older versions",
         %{env_a: env_a} do
      # Push 5 more versions, each containing the term. Without DISTINCT-ON
      # semantics this would surface 6 hits for one env.
      for _ <- 1..5 do
        create_state(env_a, %{
          value: ~s({"resources":[{"type":"aws_iam_role","name":"deploy_bot"}]})
        })
      end

      super_user = create_super()
      results = StateContext.search_states_for_user("deploy_bot", super_user)

      assert length(results) == 1
    end
  end

  describe "search_states_for_user/3 — RBAC scoping" do
    test "regular user with no grants sees nothing" do
      user = create_user()
      assert StateContext.search_states_for_user("deploy_bot", user) == []
    end

    test "regular user with planner on project A sees project A only", %{project_a: project_a} do
      user = create_user()
      planner = RoleContext.get_role_by_name("planner")
      {:ok, _} = UserProjectContext.assign_role(user.id, project_a.id, planner.id)

      # deploy_bot lives in project A
      results = StateContext.search_states_for_user("deploy_bot", user)
      assert [%{project: %{slug: "proj-a"}}] = results

      # backups lives in project B — must not leak
      assert StateContext.search_states_for_user("backups", user) == []
    end

    test "regular user without state:read (e.g. a custom role) is filtered out",
         %{project_a: project_a} do
      user = create_user()

      # Build a custom role with no permissions at all (not even state:read).
      {:ok, no_read_role} =
        RoleContext.create_role(%{
          name: "no_read_#{System.unique_integer([:positive])}",
          permissions: []
        })

      {:ok, _} = UserProjectContext.assign_role(user.id, project_a.id, no_read_role.id)

      # User has a grant on the project but the role is missing state:read,
      # so the result must be filtered out.
      assert StateContext.search_states_for_user("deploy_bot", user) == []
    end

    test "env-scoped grant only surfaces that env", %{project_a: project_a, env_a: env_a} do
      # env_a has the matching state; add a second env on project_a with its
      # own matching state. Grant the user planner only on env_a — they
      # should see env_a's hit but not the new env.
      env_a2 = create_env(project_a, %{name: "staging", slug: "staging"})

      create_state(env_a2, %{
        value: ~s({"resources":[{"type":"aws_iam_role","name":"deploy_bot"}]})
      })

      user = create_user()
      planner = RoleContext.get_role_by_name("planner")
      {:ok, _} = UserProjectContext.assign_role(user.id, project_a.id, planner.id, nil, env_a.id)

      results = StateContext.search_states_for_user("deploy_bot", user)
      env_slugs = Enum.map(results, & &1.environment.slug) |> Enum.sort()

      assert env_slugs == ["prod"]
    end
  end

  describe "search_states_for_user/3 — limits" do
    test ":limit caps the final result count", %{env_a: env_a, env_b: env_b} do
      # Add a second matching state per env so we have 2 candidates total.
      create_state(env_a, %{
        value: ~s({"resources":[{"type":"aws_kms_key","name":"shared_kms"}]})
      })

      create_state(env_b, %{
        value: ~s({"resources":[{"type":"aws_kms_key","name":"shared_kms"}]})
      })

      super_user = create_super()
      assert length(StateContext.search_states_for_user("shared_kms", super_user, limit: 1)) == 1
    end
  end
end

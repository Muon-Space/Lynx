defmodule LynxWeb.ProjectLiveTest do
  use LynxWeb.LiveCase

  alias Lynx.Module.OIDCBackendModule
  alias Lynx.Context.EnvironmentContext

  setup %{conn: conn} do
    user = create_user()
    workspace = create_workspace()
    project = create_project(%{workspace_id: workspace.id})
    {:ok, conn: log_in_user(conn, user), user: user, workspace: workspace, project: project}
  end

  defp project_path(project), do: "/admin/projects/#{project.uuid}"

  defp create_provider!(name \\ "TestProvider") do
    {:ok, provider} =
      OIDCBackendModule.create_provider(%{
        name: name,
        discovery_url: "https://example.com/.well-known/openid-configuration",
        audience: "test-audience"
      })

    provider
  end

  describe "mount" do
    test "renders project name and breadcrumb", %{conn: conn, project: project, workspace: ws} do
      {:ok, _view, html} = live(conn, project_path(project))
      assert html =~ project.name
      assert html =~ ws.name
    end

    test "shows empty environments table", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, project_path(project))
      assert html =~ "No records found."
    end

    test "lists existing environments", %{conn: conn, project: project} do
      env = create_env(project, %{name: "Staging", slug: "staging"})
      {:ok, _view, html} = live(conn, project_path(project))
      assert html =~ env.name
      assert html =~ "Not Locked"
    end
  end

  describe "Add Environment" do
    test "modal opens and closes", %{conn: conn, project: project} do
      {:ok, view, _} = live(conn, project_path(project))

      refute has_element?(view, "#add-env")

      render_click(view, "show_add_env", %{})
      assert has_element?(view, "#add-env")

      render_click(view, "hide_add_env", %{})
      refute has_element?(view, "#add-env")
    end

    test "env_form_change auto-derives slug from name", %{conn: conn, project: project} do
      {:ok, view, _} = live(conn, project_path(project))
      render_click(view, "show_add_env", %{})

      render_change(view, "env_form_change", %{"name" => "My Env Name!"})

      html = render(view)
      assert html =~ ~s(value="my-env-name")
    end

    test "create_env inserts a new env and reloads list", %{conn: conn, project: project} do
      {:ok, view, _} = live(conn, project_path(project))
      render_click(view, "show_add_env", %{})

      render_submit(view, "create_env", %{
        "name" => "Production",
        "slug" => "production",
        "username" => "u1",
        "secret" => "s1"
      })

      html = render(view)
      assert html =~ "Environment created"
      assert html =~ "Production"
      refute has_element?(view, "#add-env")

      # Verify in DB
      envs = EnvironmentContext.get_project_envs(project.id, 0, 10)
      assert Enum.any?(envs, &(&1.name == "Production"))
    end
  end

  describe "Edit Environment" do
    test "edit modal opens with current values", %{conn: conn, project: project} do
      env = create_env(project, %{name: "Old Name", slug: "old-slug"})
      {:ok, view, _} = live(conn, project_path(project))

      render_click(view, "edit_env", %{"uuid" => env.uuid})

      assert has_element?(view, "#edit-env")
      html = render(view)
      assert html =~ ~s(value="Old Name")
      assert html =~ ~s(value="old-slug")
    end

    test "update_env changes name + slug, reloads list", %{conn: conn, project: project} do
      env = create_env(project, %{name: "Old", slug: "old"})
      {:ok, view, _} = live(conn, project_path(project))

      render_click(view, "edit_env", %{"uuid" => env.uuid})

      render_submit(view, "update_env", %{
        "name" => "Renamed",
        "slug" => "renamed",
        "username" => env.username,
        "secret" => env.secret
      })

      html = render(view)
      assert html =~ "Environment updated"
      assert html =~ "Renamed"
      refute html =~ "Old"

      reloaded = EnvironmentContext.get_env_by_uuid(env.uuid)
      assert reloaded.name == "Renamed"
      assert reloaded.slug == "renamed"
    end
  end

  describe "OIDC Rules modal" do
    test "show_oidc_rules opens modal scoped to env", %{conn: conn, project: project} do
      env = create_env(project, %{name: "Prod"})
      {:ok, view, _} = live(conn, project_path(project))

      render_click(view, "show_oidc_rules", %{"uuid" => env.uuid})

      assert has_element?(view, "#oidc-rules")
      assert render(view) =~ "OIDC Access Rules"
      assert render(view) =~ "Prod"
      assert render(view) =~ "No OIDC access rules"
    end

    test "show_add_rule reveals the rule form, hide_add_rule hides it", %{
      conn: conn,
      project: project
    } do
      env = create_env(project)
      {:ok, view, _} = live(conn, project_path(project))

      render_click(view, "show_oidc_rules", %{"uuid" => env.uuid})

      refute has_element?(view, "form[phx-submit=\"create_rule\"]")
      render_click(view, "show_add_rule", %{})
      assert has_element?(view, "form[phx-submit=\"create_rule\"]")

      render_click(view, "hide_add_rule", %{})
      refute has_element?(view, "form[phx-submit=\"create_rule\"]")
    end

    test "create_rule with valid provider + claims persists rule", %{conn: conn, project: project} do
      env = create_env(project)
      provider = create_provider!()
      {:ok, view, _} = live(conn, project_path(project))

      render_click(view, "show_oidc_rules", %{"uuid" => env.uuid})
      render_click(view, "show_add_rule", %{})

      render_submit(view, "create_rule", %{
        "provider_id" => provider.uuid,
        "rule_name" => "ci-deploy",
        "claims" => "repository=org/infra"
      })

      html = render(view)
      assert html =~ "Rule created"
      assert html =~ "ci-deploy"

      rules = OIDCBackendModule.list_rules_by_environment(env.id)
      assert length(rules) == 1
      assert hd(rules).name == "ci-deploy"
    end

    test "rule rows show the provider name", %{conn: conn, project: project} do
      env = create_env(project)
      provider = create_provider!("Acme GitHub Actions")

      {:ok, _rule} =
        OIDCBackendModule.create_rule(%{
          name: "deploy",
          claim_rules: ~s([{"claim":"repo","operator":"eq","value":"org/x"}]),
          provider_id: provider.id,
          environment_id: env.id
        })

      {:ok, view, _} = live(conn, project_path(project))
      render_click(view, "show_oidc_rules", %{"uuid" => env.uuid})

      html = render(view)
      assert html =~ "Provider"
      assert html =~ "Acme GitHub Actions"
    end

    test "Save Rule button is disabled until a provider is selected", %{
      conn: conn,
      project: project
    } do
      env = create_env(project)
      _provider = create_provider!()

      {:ok, view, _} = live(conn, project_path(project))
      render_click(view, "show_oidc_rules", %{"uuid" => env.uuid})
      render_click(view, "show_add_rule", %{})

      assert has_element?(view, "button[type=\"submit\"][disabled]", "Save Rule")
      # Inline hint surfaces the requirement
      assert render(view) =~ "Provider is required"
    end

    test "rule_form_change with a provider enables Save Rule", %{conn: conn, project: project} do
      env = create_env(project)
      provider = create_provider!()

      {:ok, view, _} = live(conn, project_path(project))
      render_click(view, "show_oidc_rules", %{"uuid" => env.uuid})
      render_click(view, "show_add_rule", %{})

      render_change(view, "rule_form_change", %{
        "provider_id" => provider.uuid,
        "rule_name" => "",
        "claims" => ""
      })

      refute has_element?(view, "button[type=\"submit\"][disabled]", "Save Rule")
      assert has_element?(view, "button[type=\"submit\"]", "Save Rule")
      refute render(view) =~ "Provider is required"
    end

    test "create_rule with empty provider_id is still safe at the server", %{
      conn: conn,
      project: project
    } do
      # Server-side defense in depth: even if a client bypasses the disabled
      # button (programmatic submit), the handler must not crash and must
      # not persist a rule. Previously this raised Ecto.Query.CastError.
      env = create_env(project)
      {:ok, view, _} = live(conn, project_path(project))

      render_click(view, "show_oidc_rules", %{"uuid" => env.uuid})
      render_click(view, "show_add_rule", %{})

      render_submit(view, "create_rule", %{
        "provider_id" => "",
        "rule_name" => "x",
        "claims" => "k=v"
      })

      html = render(view)
      assert html =~ "Provider not found"
      assert OIDCBackendModule.list_rules_by_environment(env.id) == []
    end

    test "delete_rule removes a rule", %{conn: conn, project: project} do
      env = create_env(project)
      provider = create_provider!()

      {:ok, rule} =
        OIDCBackendModule.create_rule(%{
          name: "to-delete",
          claim_rules: ~s([{"claim":"x","operator":"eq","value":"y"}]),
          provider_id: provider.id,
          environment_id: env.id
        })

      {:ok, view, _} = live(conn, project_path(project))
      render_click(view, "show_oidc_rules", %{"uuid" => env.uuid})

      render_click(view, "delete_rule", %{"uuid" => rule.uuid})

      html = render(view)
      assert html =~ "Rule deleted"
      assert OIDCBackendModule.list_rules_by_environment(env.id) == []
    end
  end

  describe "OIDC rule add after env edit (regression for known bug)" do
    test "rule can be added after editing env name and slug", %{conn: conn, project: project} do
      env = create_env(project, %{name: "Original", slug: "original"})
      provider = create_provider!()

      {:ok, view, _} = live(conn, project_path(project))

      # Edit the env's name + slug
      render_click(view, "edit_env", %{"uuid" => env.uuid})

      render_submit(view, "update_env", %{
        "name" => "Renamed",
        "slug" => "renamed",
        "username" => env.username,
        "secret" => env.secret
      })

      assert render(view) =~ "Environment updated"

      # Now open OIDC rules modal for the *same* env (uuid unchanged)
      render_click(view, "show_oidc_rules", %{"uuid" => env.uuid})
      assert has_element?(view, "#oidc-rules")

      # Add a rule
      render_click(view, "show_add_rule", %{})

      render_submit(view, "create_rule", %{
        "provider_id" => provider.uuid,
        "rule_name" => "after-edit-rule",
        "claims" => "repo=org/x"
      })

      html = render(view)
      assert html =~ "Rule created", "expected flash :info but got: #{inspect(html_flash(html))}"

      rules = OIDCBackendModule.list_rules_by_environment(env.id)
      assert length(rules) == 1
      assert hd(rules).name == "after-edit-rule"
    end
  end

  describe "delete_env" do
    test "deletes env and reloads list", %{conn: conn, project: project} do
      env = create_env(project, %{name: "ToDelete"})
      {:ok, view, _} = live(conn, project_path(project))

      render_click(view, "delete_env", %{"uuid" => env.uuid})

      html = render(view)
      assert html =~ "Environment deleted"
      refute html =~ "ToDelete"
    end
  end

  describe "force_lock / force_unlock" do
    test "force_lock locks the env, badge swaps action to force_unlock", %{
      conn: conn,
      project: project
    } do
      env = create_env(project)
      {:ok, view, _} = live(conn, project_path(project))

      # Initially the lock badge offers a force_lock action
      assert has_element?(
               view,
               "[phx-value-event=\"force_lock\"][phx-value-uuid=\"#{env.uuid}\"]"
             )

      render_click(view, "force_lock", %{"uuid" => env.uuid})

      assert render(view) =~ "Environment locked"

      # After locking, the badge offers force_unlock instead — that's the
      # observable behavior change, regardless of badge color/text styling.
      assert has_element?(
               view,
               "[phx-value-event=\"force_unlock\"][phx-value-uuid=\"#{env.uuid}\"]"
             )

      refute has_element?(
               view,
               "[phx-value-event=\"force_lock\"][phx-value-uuid=\"#{env.uuid}\"]"
             )
    end

    test "force_unlock unlocks the env, badge swaps action to force_lock", %{
      conn: conn,
      project: project
    } do
      env = create_env(project)
      create_lock(env, %{is_active: true, sub_path: ""})

      {:ok, view, _} = live(conn, project_path(project))

      assert has_element?(
               view,
               "[phx-value-event=\"force_unlock\"][phx-value-uuid=\"#{env.uuid}\"]"
             )

      render_click(view, "force_unlock", %{"uuid" => env.uuid})

      assert render(view) =~ "Environment unlocked"

      assert has_element?(
               view,
               "[phx-value-event=\"force_lock\"][phx-value-uuid=\"#{env.uuid}\"]"
             )

      refute has_element?(
               view,
               "[phx-value-event=\"force_unlock\"][phx-value-uuid=\"#{env.uuid}\"]"
             )
    end
  end

  defp html_flash(html) do
    case Regex.run(~r/bg-flash-(error|success)-bg[^>]*>(.+?)<\/div>/s, html) do
      [_, kind, body] -> "#{kind}: #{String.trim(body)}"
      _ -> "no flash detected"
    end
  end
end

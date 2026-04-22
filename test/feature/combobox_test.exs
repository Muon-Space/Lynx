defmodule LynxWeb.Feature.ComboboxTest do
  @moduledoc """
  The Project Access add-team / add-user comboboxes (`.Combobox` hook) are
  pure-browser: keyboard nav, click-outside-to-close, chip rendering, and a
  hidden `<input>` synced from JS state. LV tests can't drive any of that.

  This pins the happy path: open dropdown → click an option → submit form →
  team grant is created. If `.Combobox` regresses (chip not rendered, hidden
  input not synced, click-outside trapping clicks…) admins literally can't
  grant access on a project.
  """
  use LynxWeb.FeatureCase, async: false

  alias Lynx.Context.{ProjectContext, RoleContext, TeamContext}

  setup do
    mark_installed()
    user = create_super()
    workspace = create_workspace()
    project = create_project(%{workspace_id: workspace.id})

    {:ok, team} =
      TeamContext.create_team_from_data(%{name: "Platform", slug: "plat", description: "x"})

    %{user: user, project: project, team: team}
  end

  test "open combobox, click team option, submit → team grant persisted",
       %{conn: conn, user: user, project: project, team: team} do
    conn
    |> add_lynx_session(user)
    |> visit("/admin/projects/#{project.uuid}")
    |> assert_has("h3", text: "Project Access")
    # Open the team combobox by clicking its trigger
    |> PhoenixTest.Playwright.click("#add-team-id-trigger")
    # Option list is server-rendered; click the Platform row
    |> PhoenixTest.Playwright.click(~s(#add-team-id [data-option][data-value="#{team.uuid}"]))
    # The chip should now show the team name in the trigger
    |> assert_has("#add-team-id-trigger", text: "Platform")
    # Two "Add" buttons on the page (team form + user form). Scope by form.
    |> within(~s(form[phx-submit="add_team_access"]), &click_button(&1, "Add"))
    |> assert_has("body", text: "Team access granted")

    # Server state truth check: a grant exists for this team on the project.
    assignments = ProjectContext.list_project_team_assignments(project.id)
    applier = RoleContext.get_role_by_name("applier")

    assert Enum.any?(assignments, fn {t, pt} ->
             t.id == team.id and pt.role_id == applier.id
           end)
  end
end

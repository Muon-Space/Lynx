defmodule LynxWeb.Feature.DateInputTest do
  @moduledoc """
  `<.date_input>` wires Flatpickr around a text input. The hook listens
  for Flatpickr's `onChange`/`onClose` and re-dispatches a bubbling
  `input` event so the enclosing `<form phx-change>` fires. If any link in
  that chain breaks (Flatpickr instance not bound, event not dispatched,
  form change handler not parsing the field), `expires_at` silently never
  reaches the server and grants become permanent — high-blast-radius
  silent failure.

  Drives Flatpickr through its `_flatpickr` instance attached to the input
  element (`fp.setDate(date, true)` triggers onChange) so the test exercises
  the same code path a real user click on the calendar would.
  """
  use LynxWeb.FeatureCase, async: false

  alias Lynx.Context.{ProjectContext, TeamContext}

  setup do
    mark_installed()
    user = create_super()
    workspace = create_workspace()
    project = create_project(%{workspace_id: workspace.id})

    {:ok, team} =
      TeamContext.create_team_from_data(%{name: "Ephemeral", slug: "eph", description: "x"})

    %{user: user, project: project, team: team}
  end

  test "Flatpickr setDate fires the form change → expires_at lands on the grant",
       %{conn: conn, user: user, project: project, team: team} do
    expiry = "2099-12-31"

    conn
    |> add_lynx_session(user)
    |> visit("/admin/projects/#{project.uuid}")
    |> assert_has("h3", text: "Project Access")
    |> PhoenixTest.Playwright.click("#add-team-id-trigger")
    |> PhoenixTest.Playwright.click(~s(#add-team-id [data-option][data-value="#{team.uuid}"]))
    # Drive the picker through its bound instance — same path as a real
    # calendar click. `true` second arg makes setDate trigger onChange.
    |> PhoenixTest.Playwright.evaluate("""
      document.querySelector('#add-team-expires [data-input]')._flatpickr.setDate('#{expiry}', true)
    """)
    |> within(~s(form[phx-submit="add_team_access"]), &click_button(&1, "Add"))
    |> assert_has("body", text: "Team access granted")

    # Server truth: the grant carries the picked expiry (end-of-day UTC).
    [{_team, pt}] = ProjectContext.list_project_team_assignments(project.id)
    refute is_nil(pt.expires_at)
    assert Date.to_iso8601(DateTime.to_date(pt.expires_at)) == expiry
  end
end

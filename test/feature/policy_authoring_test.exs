defmodule LynxWeb.Feature.PolicyAuthoringTest do
  @moduledoc """
  Browser-driven coverage for the policy authoring flow (issue #38).

  ConnTest already exercises mount, perm gating, and the LV event
  handlers in isolation. The things you can ONLY catch with a real
  browser are exactly the things this file pins:

    * Monaco editor actually mounts (live_monaco_editor's lazy CDN
      loader resolves; the hook attaches; the editor instance accepts
      its initial value)
    * The validation banner advances out of `:validating` once the
      debounced server roundtrip completes
    * Row click on the policies table navigates to the per-policy
      detail page
    * Edit Policy on the detail page swaps view → edit (URL gains
      `?edit=1`, form fields appear) and Cancel reverses it

  Engine is the in-memory `Stub` (`config/test.exs` default) so tests
  don't need OPA on PATH. The `:opa` integration suite separately
  pins the real-OPA HTTP wire format.
  """
  use LynxWeb.FeatureCase, async: false

  alias Lynx.Context.PolicyContext

  setup do
    mark_installed()
    user = create_super()
    workspace = create_workspace()
    project = create_project(%{workspace_id: workspace.id, name: "Infra"})

    {:ok, policy} =
      PolicyContext.create_policy(
        PolicyContext.new_policy(%{
          name: "no-public-buckets",
          description: "Block public S3 buckets",
          project_id: project.id,
          rego_source: "package x\n\ndeny[msg] { false; msg := \"x\" }"
        })
      )

    %{user: user, project: project, policy: policy}
  end

  test "Add Policy form mounts Monaco + validates the example rego", %{
    conn: conn,
    user: user,
    project: project
  } do
    conn
    |> add_lynx_session(user)
    |> visit("/admin/projects/#{project.uuid}/policies")
    |> click_button("Add Policy")
    # New Policy heading is the form's signal that the editor card rendered
    # and the script tag for the Monaco loader has been emitted.
    |> assert_has("h3", text: "New Policy")
    # Side-panel reference + form fields are part of the same render —
    # if Monaco failed to wire up, the validation banner below it would
    # still be there but the editor area would be empty. We assert on
    # the panel since it's a stable DOM element next to the editor.
    |> assert_has("body", text: "Available")
    |> assert_has("body", text: "input.resource_changes[]")
    # The default-rego example has a `package main` line — Stub validates
    # any source containing "package ", so the banner advances from
    # "Validating…" to the success label after the 400ms debounce. This
    # whole flow only works when the editor really mounted + dispatched
    # its `set_rego` event.
    |> assert_has("body", text: "Validated against OPA")
  end

  test "View link in the policies table action column navigates to the per-policy detail page",
       %{conn: conn, user: user, project: project} do
    # The row itself is also clickable (`row_click={JS.navigate(...)}`),
    # but that's a JS-driven click on a `<td>` rather than an `<a>` tag —
    # not directly addressable via `click_link`. The action-column "View"
    # link goes to the same destination and is the explicit affordance,
    # which is what we pin here.
    conn
    |> add_lynx_session(user)
    |> visit("/admin/projects/#{project.uuid}/policies")
    |> click_link("View")
    |> assert_has("body", text: "Edit Policy")
    |> assert_has("body", text: "Block public S3 buckets")
  end

  test "Edit Policy → ?edit=1 form, Cancel returns to view mode",
       %{conn: conn, user: user, policy: policy} do
    conn
    |> add_lynx_session(user)
    |> visit("/admin/policies/#{policy.uuid}")
    |> assert_has("body", text: "Edit Policy")
    |> click_button("Edit Policy")
    # Form rendered: Name input now visible + Save / Cancel buttons.
    # The header swaps "Edit Policy" → "Cancel" so testing presence of
    # both elements proves the toggle.
    |> assert_has("input[name=name]")
    |> assert_has("button", text: "Save")
    |> assert_has("button", text: "Cancel")
    |> click_button("Cancel")
    # Cancel push_patches back to the bare URL — the Edit Policy
    # button reappears and the input element is gone.
    |> assert_has("button", text: "Edit Policy")
    |> refute_has("input[name=name]")
  end
end

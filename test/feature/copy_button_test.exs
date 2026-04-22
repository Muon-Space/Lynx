defmodule LynxWeb.Feature.CopyButtonTest do
  @moduledoc """
  Browser coverage for the generic `<.copy_button>` component (`.CopyButton`
  hook in `core_components.ex`). The hook reads `data-target`'s textContent
  and writes to the clipboard synchronously inside the click handler, which
  preserves the user-activation gesture browsers require — but a future
  change could re-introduce the same async-chain bug we just fixed for
  `.CopyApiKey`. This is the regression bar.

  Target: env page's backend-config block (`#backend-config-content`).
  """
  use LynxWeb.FeatureCase, async: false

  setup do
    mark_installed()
    user = create_super()
    workspace = create_workspace(%{slug: "feat-ws"})
    project = create_project(%{workspace_id: workspace.id, slug: "feat-proj"})
    env = create_env(project, %{name: "prod", slug: "prod", username: "u", secret: "s"})
    %{user: user, project: project, env: env}
  end

  test "Copy on the env backend-config block writes the HCL to the clipboard",
       %{conn: conn, user: user, project: project, env: env} do
    conn
    |> add_lynx_session(user)
    |> visit("/admin/projects/#{project.uuid}/environments/#{env.uuid}")
    |> assert_has("#backend-config-content")
    |> click_button("Copy")
    # The block contains a Terraform HTTP backend with this env's URL +
    # creds — assert on a stable substring instead of the whole HCL.
    |> assert_clipboard_matches(~r/backend "http"/)
    |> assert_clipboard_matches(~r/feat-ws\/feat-proj\/prod\/state/)
  end
end

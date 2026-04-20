defmodule LynxWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import LynxWeb.CoreComponents

  describe "badge/1" do
    test "renders inner content" do
      assigns = %{}
      html = h(~H[<.badge color="green">Active</.badge>])
      assert html =~ "Active"
    end

    test "different color values produce different markup" do
      # Behavioral check: the color attr changes the rendered output.
      # Avoids coupling to specific Tailwind class names.
      assigns = %{}
      green = h(~H[<.badge color="green">x</.badge>])
      red = h(~H[<.badge color="red">x</.badge>])
      yellow = h(~H[<.badge color="yellow">x</.badge>])
      neutral = h(~H[<.badge color="fuchsia">x</.badge>])

      refute green == red
      refute green == yellow
      refute red == yellow
      # Unknown color falls back deterministically (same as another unknown)
      assert neutral == h(~H[<.badge color="not-a-color">x</.badge>])
    end
  end

  describe "button/1" do
    test "default renders a button element with content" do
      assigns = %{}
      html = h(~H[<.button>Save</.button>])
      assert html =~ "<button"
      assert html =~ ~s(type="button")
      assert html =~ "Save"
    end

    test "type=submit when explicitly set" do
      assigns = %{}
      html = h(~H[<.button type="submit">Go</.button>])
      assert html =~ ~s(type="submit")
    end

    test "global attributes pass through (phx-click, phx-value-id)" do
      assigns = %{}
      html = h(~H[<.button phx-click="do_thing" phx-value-id="42">Go</.button>])
      assert html =~ ~s(phx-click="do_thing")
      assert html =~ ~s(phx-value-id="42")
    end

    test "different variants produce different markup" do
      assigns = %{}
      primary = h(~H[<.button variant="primary">x</.button>])
      danger = h(~H[<.button variant="danger">x</.button>])
      secondary = h(~H[<.button variant="secondary">x</.button>])
      ghost = h(~H[<.button variant="ghost">x</.button>])

      refute primary == danger
      refute primary == secondary
      refute primary == ghost
      refute danger == secondary
    end

    test "different sizes produce different markup" do
      assigns = %{}
      sm = h(~H[<.button size="sm">x</.button>])
      md = h(~H[<.button size="md">x</.button>])
      lg = h(~H[<.button size="lg">x</.button>])

      refute sm == md
      refute md == lg
    end
  end

  describe "modal/1" do
    test "renders id and inner content" do
      assigns = %{}
      html = h(~H[<.modal id="my-modal">Modal body</.modal>])
      assert html =~ ~s(id="my-modal")
      assert html =~ "Modal body"
    end

    test "shows close button wired to on_close event" do
      assigns = %{}
      html = h(~H[<.modal id="x" on_close="cancel">body</.modal>])
      assert html =~ ~s(phx-click="cancel")
    end

    test "no close button when on_close nil" do
      assigns = %{}
      html = h(~H[<.modal id="x">body</.modal>])
      refute html =~ "&times;"
    end
  end

  describe "confirm_dialog/1" do
    test "renders message and confirm event" do
      assigns = %{}

      html =
        h(~H"""
        <.confirm_dialog
          message="Delete forever?"
          confirm_event="delete_thing"
          confirm_value={%{uuid: "abc-123"}}
        />
        """)

      assert html =~ "Delete forever?"
      assert html =~ ~s(phx-click="delete_thing")
      assert html =~ ~s(phx-value-uuid="abc-123")
      assert html =~ ~s(phx-click="cancel_confirm")
    end

    test "default title shown" do
      assigns = %{}
      html = h(~H[<.confirm_dialog message="x" confirm_event="y" />])
      assert html =~ "Are you sure?"
    end
  end

  describe "table/1" do
    test "renders rows and column labels" do
      assigns = %{rows: [%{name: "Alpha"}, %{name: "Beta"}]}

      html =
        h(~H"""
        <.table rows={@rows}>
          <:col :let={r} label="Name">{r.name}</:col>
        </.table>
        """)

      assert html =~ "Name"
      assert html =~ "Alpha"
      assert html =~ "Beta"
    end

    test "shows empty message" do
      assigns = %{}

      html =
        h(~H"""
        <.table rows={[]} empty_message="Nothing here">
          <:col label="Name">x</:col>
        </.table>
        """)

      assert html =~ "Nothing here"
    end

    test "renders action slot when provided" do
      assigns = %{rows: [%{name: "Alpha", id: 1}]}

      html =
        h(~H"""
        <.table rows={@rows}>
          <:col :let={r} label="Name">{r.name}</:col>
          <:action :let={r}>
            <button id={"act-#{r.id}"}>Edit</button>
          </:action>
        </.table>
        """)

      assert html =~ "Actions"
      assert html =~ ~s(id="act-1")
      assert html =~ "Edit"
    end
  end

  describe "pagination/1" do
    test "hidden when only one page" do
      assigns = %{}
      html = h(~H[<.pagination page={1} total_pages={1} />])
      refute html =~ "Previous"
    end

    test "renders prev/next when multiple pages" do
      assigns = %{}
      html = h(~H[<.pagination page={2} total_pages={5} />])
      assert html =~ "Previous"
      assert html =~ "Next"
      assert html =~ "2 / 5"
    end

    test "disables prev on first page" do
      assigns = %{}
      html = h(~H[<.pagination page={1} total_pages={3} />])
      assert html =~ ~r/phx-click="prev_page"[^>]*disabled/
    end

    test "disables next on last page" do
      assigns = %{}
      html = h(~H[<.pagination page={3} total_pages={3} />])
      assert html =~ ~r/phx-click="next_page"[^>]*disabled/
    end
  end

  describe "input/1 text" do
    test "renders label, name, value" do
      assigns = %{}

      html =
        h(~H"""
        <.input id="email" name="user[email]" label="Email" value="a@b.com" type="email" />
        """)

      assert html =~ "Email"
      assert html =~ ~s(name="user[email]")
      assert html =~ ~s(value="a@b.com")
      assert html =~ ~s(type="email")
    end

    test "renders hint when provided" do
      assigns = %{}
      html = h(~H[<.input name="x" value="" hint="Helpful tip" />])
      assert html =~ "Helpful tip"
    end

    test "renders errors when present" do
      assigns = %{}

      html =
        h(~H"""
        <.input name="x" value="" errors={["is required"]} />
        """)

      assert html =~ "is required"
    end
  end

  describe "input/1 checkbox" do
    test "renders hidden false + checkbox true pair" do
      assigns = %{}

      html =
        h(~H"""
        <.input id="active" name="user[active]" type="checkbox" value="true" label="Active" />
        """)

      assert html =~ ~s(type="hidden")
      assert html =~ ~s(value="false")
      assert html =~ ~s(type="checkbox")
      assert html =~ "checked"
      assert html =~ "Active"
    end
  end

  describe "input/1 select" do
    test "renders options and selected label" do
      assigns = %{}

      html =
        h(~H"""
        <.input
          id="role"
          name="user[role]"
          type="select"
          label="Role"
          value="super"
          options={[{"User", "user"}, {"Super", "super"}]}
        />
        """)

      assert html =~ "Role"
      assert html =~ ~s(name="user[role]")
      assert html =~ ~s(value="super")
      assert html =~ "User"
      assert html =~ "Super"
    end

    test "multiple shows comma-joined labels" do
      assigns = %{}

      html =
        h(~H"""
        <.input
          id="teams"
          name="user[teams]"
          type="select"
          multiple
          value={["1", "3"]}
          options={[{"Alpha", "1"}, {"Beta", "2"}, {"Gamma", "3"}]}
        />
        """)

      assert html =~ "Alpha, Gamma"
    end

    test "uses prompt when no value selected" do
      assigns = %{}

      html =
        h(~H"""
        <.input
          id="x"
          name="x"
          type="select"
          value=""
          prompt="Pick one"
          options={[{"A", "a"}]}
        />
        """)

      assert html =~ "Pick one"
    end
  end

  describe "input/1 textarea" do
    test "renders value as content" do
      assigns = %{}

      html =
        h(~H"""
        <.input id="bio" name="user[bio]" type="textarea" value="Hello world" />
        """)

      assert html =~ "<textarea"
      assert html =~ "Hello world"
    end
  end

  describe "page_header/1" do
    test "renders title and optional subtitle" do
      assigns = %{}
      html = h(~H[<.page_header title="Workspaces" subtitle="Manage them" />])
      assert html =~ "Workspaces"
      assert html =~ "Manage them"
    end

    test "no subtitle when nil" do
      assigns = %{}
      html = h(~H[<.page_header title="Workspaces" />])
      assert html =~ "Workspaces"
      refute html =~ "<p"
    end
  end

  describe "card/1" do
    test "renders inner content" do
      assigns = %{}
      html = h(~H[<.card>Card body</.card>])
      assert html =~ "Card body"
    end

    test "merges custom class with defaults" do
      assigns = %{}
      html = h(~H[<.card class="custom-marker-xyz">x</.card>])
      assert html =~ "custom-marker-xyz"
    end
  end

  describe "flash/1" do
    test "info flash uses ✓ symbol and contains message" do
      assigns = %{flash: %{"info" => "Saved"}}
      html = h(~H[<.flash flash={@flash} kind={:info} />])
      assert html =~ "Saved"
      assert html =~ ~s(id="flash-info")
      assert html =~ "✓"
      refute html =~ "✕"
    end

    test "error flash uses ✕ symbol and contains message" do
      assigns = %{flash: %{"error" => "Boom"}}
      html = h(~H[<.flash flash={@flash} kind={:error} />])
      assert html =~ "Boom"
      assert html =~ ~s(id="flash-error")
      assert html =~ "✕"
      refute html =~ "✓"
    end

    test "renders nothing when message missing" do
      assigns = %{}
      html = h(~H[<.flash flash={%{}} kind={:info} />])
      refute html =~ ~s(id="flash-info")
    end
  end

  describe "role_assignments_summary/1" do
    test "groups projects by role and shows the role badge once per group" do
      assigns = %{
        items: [
          %{project: %{name: "Alpha", uuid: "u1"}, role_name: "applier"},
          %{project: %{name: "Beta", uuid: "u2"}, role_name: "applier"},
          %{project: %{name: "Gamma", uuid: "u3"}, role_name: "admin"}
        ]
      }

      html = h(~H[<.role_assignments_summary assignments={@items} />])

      # Each role appears exactly once as a badge label.
      assert length(Regex.scan(~r/Applier/, html)) == 1
      assert length(Regex.scan(~r/Admin/, html)) == 1
      # All projects render as links.
      assert html =~ ~s(href="/admin/projects/u1")
      assert html =~ "Alpha"
      assert html =~ "Beta"
      assert html =~ "Gamma"
    end

    test "orders role groups admin > applier > planner > custom" do
      assigns = %{
        items: [
          %{project: %{name: "P1", uuid: "u1"}, role_name: "planner"},
          %{project: %{name: "P2", uuid: "u2"}, role_name: "admin"},
          %{project: %{name: "P3", uuid: "u3"}, role_name: "applier"}
        ]
      }

      html = h(~H[<.role_assignments_summary assignments={@items} />])

      [admin_pos, applier_pos, planner_pos] =
        Enum.map(["Admin", "Applier", "Planner"], fn label ->
          {idx, _} = :binary.match(html, label)
          idx
        end)

      assert admin_pos < applier_pos
      assert applier_pos < planner_pos
    end

    test "shows empty_message when no assignments" do
      assigns = %{empty: []}

      html =
        h(~H"""
        <.role_assignments_summary assignments={@empty} empty_message="Nothing here" />
        """)

      assert html =~ "Nothing here"
    end

    test "all_label overrides everything" do
      assigns = %{
        items: [%{project: %{name: "P1", uuid: "u1"}, role_name: "applier"}]
      }

      html =
        h(~H[<.role_assignments_summary assignments={@items} all_label="All projects (super)" />])

      assert html =~ "All projects (super)"
      refute html =~ "Applier"
      refute html =~ "P1"
    end

    test "renders source list as title attribute when provided" do
      assigns = %{
        items: [
          %{
            project: %{name: "P1", uuid: "u1"},
            role_name: "applier",
            sources: ["direct", "via Infra"]
          }
        ]
      }

      html = h(~H[<.role_assignments_summary assignments={@items} />])
      assert html =~ ~s(title="direct, via Infra")
    end
  end

  describe "nav/1" do
    test "shows user-scope links and logout for any logged-in user" do
      assigns = %{user: %{name: "Jane", role: "user"}}
      html = h(~H[<.nav current_user={@user} active="workspaces" />])
      assert html =~ ~s(href="/admin/workspaces")
      assert html =~ ~s(href="/admin/snapshots")
      assert html =~ "Jane"
      assert html =~ ~s(href="/logout")
      refute html =~ ~s(href="/admin/audit")
      refute html =~ ~s(href="/admin/settings")
      refute html =~ ~s(href="/admin/users")
      refute html =~ ~s(href="/admin/teams")
    end

    test "shows admin-only links for super user" do
      assigns = %{user: %{name: "Admin", role: "super"}}
      html = h(~H[<.nav current_user={@user} active="audit" />])
      assert html =~ ~s(href="/admin/audit")
      assert html =~ ~s(href="/admin/settings")
      assert html =~ ~s(href="/admin/users")
      assert html =~ ~s(href="/admin/teams")
    end

    test "anonymous shows only logo, no links" do
      assigns = %{}
      html = h(~H[<.nav current_user={nil} active="" />])
      refute html =~ ~s(href="/admin/workspaces")
      refute html =~ ~s(href="/logout")
    end

    test "logo renders as inline base64 data URI (no external network roundtrip)" do
      # Regression: previously two <img src="/images/ico*.png"> tags required a
      # second network roundtrip per page, causing a logo flash on slow loads.
      # The brand mark is now inlined as a base64 data URI at compile time.
      assigns = %{user: %{name: "Jane", role: "user"}}
      html = h(~H[<.nav current_user={@user} active="" />])

      # Inlined data URI present in source
      assert html =~ ~s(src="data:image/png;base64,)

      # Light/dark inversion via CSS filter (single <img>, no second network call)
      assert html =~ "invert dark:invert-0"

      # No external image references for the logo itself
      refute html =~ ~s(src="/images/ico.png")
      refute html =~ ~s(src="/images/ico-dark.png")
    end

    test "dark-mode toggle renders both icons statically (no JS-required content)" do
      # Regression: previously the toggle button rendered as <button></button>
      # and the JS hook injected the icon on mount, causing a flash of empty
      # content (or permanently broken if JS failed to load). Both icons now
      # ship in the HTML; CSS picks the right one via the .dark class.
      assigns = %{user: %{name: "Jane", role: "user"}}
      html = h(~H[<.nav current_user={@user} active="" />])

      # Both icons present
      assert html =~ "🌙"
      assert html =~ "☀️"

      # Light-mode icon hidden in dark mode
      assert html =~ ~r/<span class="dark:hidden">\s*🌙/
      # Dark-mode icon hidden in light mode (shown in dark via dark:inline)
      assert html =~ ~r/<span class="hidden dark:inline">\s*☀️/
    end
  end

  defp h(rendered), do: rendered_to_string(rendered)
end

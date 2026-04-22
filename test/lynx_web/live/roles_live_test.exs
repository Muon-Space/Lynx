defmodule LynxWeb.RolesLiveTest do
  use LynxWeb.LiveCase

  alias Lynx.Context.RoleContext

  setup %{conn: conn} do
    user = create_super()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  describe "mount" do
    test "renders Roles title + system roles", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/roles")

      assert html =~ "Roles"
      assert html =~ "Planner"
      assert html =~ "Applier"
      assert html =~ "Admin"
      # System badge appears for the seeded roles.
      assert html =~ "system"
    end

    test "non-super redirected to login", %{conn: conn} do
      regular = create_user()
      conn = log_in_user(conn, regular)
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/admin/roles")
    end
  end

  describe "create role" do
    test "form_change tracks selected permissions across re-renders", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/roles")
      render_click(view, "show_add", %{})

      # Hidden inputs from <.permission_grid> are checkboxes; we drive them
      # via render_change and assert the resulting checked state.
      html =
        render_change(view, "form_change", %{
          "name" => "Auditor",
          "permissions" => ["state:read"]
        })

      # The state:read checkbox is now checked.
      assert html =~ ~r{value="state:read"\s+checked}
    end

    test "create_role persists + closes the modal", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/roles")
      render_click(view, "show_add", %{})

      render_change(view, "form_change", %{
        "name" => "auditor",
        "permissions" => ["state:read"]
      })

      render_submit(view, "create_role", %{
        "name" => "auditor",
        "description" => "Read-only"
      })

      html = render(view)
      assert html =~ "Role created"
      assert html =~ "Auditor"
      assert RoleContext.get_role_by_name("auditor") != nil
    end
  end

  describe "edit role" do
    test "system roles can't be edited (Edit button disabled)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/roles")

      # The Edit cell for system roles renders a non-clickable label, not a
      # button. So the table contains the Edit text but not as a phx-click
      # handler for the system role rows.
      planner = RoleContext.get_role_by_name("planner")
      refute html =~ ~s(phx-value-uuid="#{planner.uuid}")
    end

    test "update_role replaces permissions", %{conn: conn} do
      {:ok, role} = RoleContext.create_role(%{name: "deployer", permissions: ["state:read"]})

      {:ok, view, _} = live(conn, "/admin/roles")
      render_click(view, "edit_role", %{"uuid" => role.uuid})

      render_change(view, "form_change", %{
        "name" => "deployer",
        "permissions" => ["state:read", "state:write"]
      })

      render_submit(view, "update_role", %{
        "name" => "deployer",
        "description" => ""
      })

      assert RoleContext.permissions_for(role.id) ==
               MapSet.new(["state:read", "state:write"])
    end
  end

  describe "delete role" do
    test "delete_role removes a custom role", %{conn: conn} do
      {:ok, role} = RoleContext.create_role(%{name: "tossme", permissions: []})

      {:ok, view, _} = live(conn, "/admin/roles")
      render_click(view, "delete_role", %{"uuid" => role.uuid})

      html = render(view)
      assert html =~ "Role deleted"
      refute html =~ "tossme"
    end

    test "Delete button hidden when role has grants", %{conn: conn} do
      {:ok, role} = RoleContext.create_role(%{name: "withgrant", permissions: []})

      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})
      user = create_user()
      {:ok, _} = Lynx.Context.UserProjectContext.assign_role(user.id, project.id, role.id)

      {:ok, _view, html} = live(conn, "/admin/roles")

      # Role appears (name is capitalized in the table). The Delete
      # `<.button>` (with phx-value-uuid) is replaced by a disabled-
      # affordance span.
      assert html =~ "Withgrant"
      refute html =~ ~s(phx-value-event="delete_role" phx-value-message="Delete role withgrant?")
    end
  end
end

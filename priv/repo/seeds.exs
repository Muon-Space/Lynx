# Idempotent dev seed. Safe to run multiple times — every step checks for
# existing state and skips. Used by `mix ecto.setup` and ad-hoc by
# `mix run priv/repo/seeds.exs`.

alias Lynx.Context.{
  EnvironmentContext,
  OPABundleTokenContext,
  PolicyContext,
  ProjectContext,
  RoleContext,
  UserContext,
  UserProjectContext,
  WorkspaceContext
}

alias Lynx.Service.Install

# 1. App install — creates app_key, app_url, etc. + the admin user.
unless Install.is_installed() do
  IO.puts("[seed] Installing app + creating admin…")

  app_key = Install.get_app_key()

  Install.store_configs(%{
    app_name: "Lynx Dev",
    app_url: "http://localhost:4000",
    app_email: "admin@example.com",
    app_key: app_key
  })

  Install.create_admin(%{
    admin_name: "Admin",
    admin_email: "admin@example.com",
    admin_password: "password123",
    app_key: app_key
  })

  IO.puts("[seed]   admin login → admin@example.com / password123")
end

# 2. Sample workspace + project + env. Slug-based lookup so re-runs reuse.
{:ok, workspace} =
  case WorkspaceContext.get_workspace_by_slug("dev") do
    nil ->
      WorkspaceContext.create_workspace(
        WorkspaceContext.new_workspace(%{
          name: "Dev Workspace",
          slug: "dev",
          description: "Local development workspace"
        })
      )

    ws ->
      {:ok, ws}
  end

{:ok, project} =
  case ProjectContext.get_project_by_slug_and_workspace("infra", workspace.id) do
    nil ->
      ProjectContext.create_project(
        ProjectContext.new_project(%{
          name: "Infra",
          slug: "infra",
          description: "Demo infra project",
          workspace_id: workspace.id
        })
      )

    p ->
      {:ok, p}
  end

{:ok, env} =
  case EnvironmentContext.get_env_by_slug_project(project.id, "production") do
    nil ->
      EnvironmentContext.create_env(
        EnvironmentContext.new_env(%{
          name: "Production",
          slug: "production",
          username: "tf-user",
          secret: "tf-secret-please-rotate",
          project_id: project.id
        })
      )

    e ->
      {:ok, e}
  end

# 3. Grant the admin direct admin role on the project so per-project
# permission checks work even when not bypassing as super.
admin = UserContext.get_user_by_email("admin@example.com")
admin_role = RoleContext.get_role_by_name("admin")

unless Enum.any?(
         RoleContext.list_user_project_access(admin),
         fn entry -> entry.project.id == project.id end
       ) do
  UserProjectContext.assign_role(admin.id, project.id, admin_role.id)
end

# 4. Sample OPA bundle token (visible in Settings → OPA). The OPA daemon
# itself is configured with a fixed token via OPA_BUNDLE_TOKEN env var,
# so this DB token is just for showing the UI flow.
unless OPABundleTokenContext.list_tokens()
       |> Enum.any?(&(&1.name == "demo-token")) do
  {:ok, %{token: token}} = OPABundleTokenContext.generate_token("demo-token")
  IO.puts("[seed] OPA bundle token (DB-managed): demo-token = #{token}")
end

# 5. Sample policy attached to the project. OPA 1.0+ syntax.
unless PolicyContext.list_policies_by_project(project.id) |> Enum.any?(&(&1.name == "no-public-buckets")) do
  PolicyContext.create_policy(
    PolicyContext.new_policy(%{
      name: "no-public-buckets",
      description: "Block S3 buckets with a public-read ACL.",
      project_id: project.id,
      enabled: true,
      rego_source: """
      package main

      deny contains msg if {
        some i
        rc := input.resource_changes[i]
        rc.type == "aws_s3_bucket"
        rc.change.after.acl == "public-read"
        msg := sprintf("S3 bucket %s is publicly readable", [rc.address])
      }
      """
    })
  )

  IO.puts("[seed] Created policy 'no-public-buckets' on project Infra")
end

IO.puts("""

[seed] Done. Try:
  - http://localhost:4000  (login admin@example.com / password123)
  - Workspaces → Dev Workspace → Infra → Production
  - Settings → OPA tab (bundle tokens)
  - Policies link on the project page

  Test the plan endpoint:
    curl -X POST -u tf-user:tf-secret-please-rotate \\
      -H 'content-type: application/json' \\
      -d '{"resource_changes":[{"address":"aws_s3_bucket.foo","type":"aws_s3_bucket","change":{"after":{"acl":"public-read"}}}]}' \\
      http://localhost:4000/tf/dev/infra/production/plan
""")

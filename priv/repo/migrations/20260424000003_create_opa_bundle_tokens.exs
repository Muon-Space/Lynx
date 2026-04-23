defmodule Lynx.Repo.Migrations.CreateOpaBundleTokens do
  @moduledoc """
  Bearer tokens for the OPA bundle endpoint (issue #38).

  Modeled on `scim_tokens`: long-lived service tokens, generated and shown
  once via the Settings UI, validated via a dedicated middleware.
  Crucially, this is NOT routed through `RoleContext` — the bundle
  endpoint isn't a project-scoped operation, it's a service identity.
  Multiple tokens supported so operators can rotate without downtime.

  The Helm chart's auto-generated token (mounted from a K8s Secret into
  both Lynx and OPA) bypasses this table entirely — see
  `OPABundleAuthMiddleware` for the env-var path. This table only
  governs the admin-managed case.
  """

  use Ecto.Migration

  def change do
    create table(:opa_bundle_tokens) do
      add :uuid, :uuid, null: false
      add :name, :string, null: false
      add :token, :string, null: false
      add :is_active, :boolean, null: false, default: true
      add :last_used_at, :utc_datetime, null: true

      timestamps()
    end

    create unique_index(:opa_bundle_tokens, [:uuid])
    create unique_index(:opa_bundle_tokens, [:token])
  end
end

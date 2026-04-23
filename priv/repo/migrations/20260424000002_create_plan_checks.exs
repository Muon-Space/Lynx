defmodule Lynx.Repo.Migrations.CreatePlanChecks do
  @moduledoc """
  Records every plan-check evaluation (issue #38). Persisted regardless of
  outcome so operators have an audit trail of what was uploaded, when, and
  what each policy said.

  `actor_signature` is a stable string identifying the credential that
  uploaded the plan (OIDC subject, user UUID, or env-secret marker). The
  apply-gate uses this to require that the apply comes from the same
  credential that produced the passing plan-check, without needing a
  separate token round-trip through Terraform.
  """

  use Ecto.Migration

  def change do
    create table(:plan_checks) do
      add :uuid, :uuid, null: false
      add :environment_id, references(:environments, on_delete: :delete_all), null: false
      add :sub_path, :string, null: false, default: ""

      # Outcome:
      #   "passed"  — every policy returned an empty deny[] list
      #   "failed"  — at least one policy returned violations
      #   "errored" — engine couldn't evaluate (OPA unreachable, policy syntax error)
      add :outcome, :string, null: false

      # JSON list of {policy_uuid, policy_name, [violation_msg, ...]} maps.
      # Stored as text + Jason-encoded so the same shape works with sqlite if
      # we ever switch.
      add :violations, :text, null: false, default: "[]"

      # The full plan body as uploaded. Compressed-on-disk by Postgres TOAST;
      # operators can prune via the existing snapshot-style retention if it
      # gets large.
      add :plan_json, :text, null: false

      add :actor_signature, :string, null: false
      add :actor_name, :string, null: true
      add :actor_type, :string, null: false

      # Apply-gate consumption. NULL = available; non-NULL = already used
      # by a state-write at that timestamp. Single-use semantics so a
      # passing plan-check authorizes exactly one apply.
      add :consumed_at, :utc_datetime, null: true

      timestamps()
    end

    create unique_index(:plan_checks, [:uuid])
    create index(:plan_checks, [:environment_id, :sub_path, :inserted_at])
    # Partial index for the apply-gate lookup: only unconsumed passing rows.
    create index(:plan_checks, [:environment_id, :sub_path, :actor_signature],
             where: "outcome = 'passed' AND consumed_at IS NULL",
             name: :plan_checks_apply_gate_idx
           )
  end
end

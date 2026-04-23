defmodule Lynx.Repo.Migrations.IndexAuditEventsActionInsertedAt do
  @moduledoc """
  Bound the per-policy detail page's recent-blocks lookup
  (`PolicyContext.recent_blocks_for_policy/2`) which scans `audit_events`
  for `action = "apply_blocked"` rows whose `metadata` JSON mentions a
  given policy uuid via ILIKE. The metadata ILIKE itself is unindexable
  by a regular B-tree, but most of the cost was the `action`/recency
  filter — this composite index lets Postgres pull recent
  apply_blocked rows cheaply, then ILIKE only that small slice.

  Existing single-column `(action)` and `(inserted_at)` indexes from
  `20260416200007_create_audit_events.exs` overlap functionally; we
  keep them for other queries (audit log filtered by action, etc.) and
  add this composite for the apply_blocked recency probe.
  """

  use Ecto.Migration

  def change do
    create index(:audit_events, [:action, :inserted_at])
  end
end

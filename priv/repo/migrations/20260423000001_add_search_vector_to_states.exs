defmodule Lynx.Repo.Migrations.AddSearchVectorToStates do
  @moduledoc """
  Postgres full-text search over the `states.value` JSON body.

  `search_vector` is a STORED generated column built with the `'simple'`
  config (no stemming — Terraform resource addresses like
  `aws_iam_role.deploy_bot` are exact identifiers, not natural language).
  Generated columns auto-populate for existing rows when added, so no
  separate backfill step is needed. Requires Postgres 12+.

  GIN index on the vector enables `@@ plainto_tsquery(...)` matches.
  Operators should benchmark size-on-disk before turning this on for
  state files >> 1 MB — see issue #37 for the perf note.
  """

  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE states
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (to_tsvector('simple', coalesce(value, ''))) STORED
    """)

    execute("CREATE INDEX states_search_vector_idx ON states USING GIN (search_vector)")
  end

  def down do
    execute("DROP INDEX IF EXISTS states_search_vector_idx")

    execute("ALTER TABLE states DROP COLUMN IF EXISTS search_vector")
  end
end

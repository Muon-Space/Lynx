defmodule Lynx.Repo.Migrations.HashTokenColumns do
  @moduledoc """
  Replace plaintext storage of high-entropy bearer tokens with
  HMAC-SHA-256(pepper, token) hashes (issue: secrets must be encrypted
  at rest). Affected columns:

    * `users.api_key`
    * `environments.secret`
    * `scim_tokens.token`
    * `opa_bundle_tokens.token`

  Each table grows two new columns and loses the plaintext one:

    * `<col>_hash`   — hex-encoded HMAC, indexed for fast equality lookup
    * `<col>_prefix` — first 8 chars of the original token, for UI display
                       so operators can identify which token is which

  Existing rows are backfilled by calling `Lynx.Service.TokenHash` —
  the runtime hash function — so the post-migration data is bit-identical
  to what the new code path would produce.

  Pepper is derived from `APP_SECRET`; rotating it invalidates every
  hashed token (intentional, see `TokenHash` moduledoc). Operators
  must NOT rotate `APP_SECRET` between deploying this migration and
  re-issuing operational tokens.

  ## Rollback

  `down/0` is intentionally not provided. Once the plaintext column is
  dropped, the original token values are lost. Rollback path is:
  redeploy the previous release (which still references plaintext
  columns) → restore the plaintext columns from a DB snapshot taken
  before this migration. Operators MUST snapshot before applying.
  """

  use Ecto.Migration

  alias Lynx.Repo
  alias Lynx.Service.TokenHash

  @tables [
    %{table: "users", col: "api_key"},
    %{table: "environments", col: "secret"},
    %{table: "scim_tokens", col: "token"},
    %{table: "opa_bundle_tokens", col: "token"}
  ]

  def up do
    Enum.each(@tables, &add_columns/1)

    # The flush ensures Postgres has the new columns committed before we
    # try to UPDATE them in the backfill step. Without it, the backfill
    # runs in the same transaction as the ALTER and the column references
    # may not yet be resolvable in some Postgres versions.
    flush()

    Enum.each(@tables, &backfill/1)

    flush()

    Enum.each(@tables, &drop_plaintext/1)
  end

  defp add_columns(%{table: table, col: col}) do
    alter table(String.to_atom(table)) do
      add String.to_atom("#{col}_hash"), :string
      add String.to_atom("#{col}_prefix"), :string
    end
  end

  # Backfill: read every row's current plaintext value, compute the
  # hash + prefix in Elixir (same code path as runtime), write back.
  # Done in a single transaction per table — these are small (typically
  # a few hundred rows total across all four tables).
  defp backfill(%{table: table, col: col}) do
    hash_col = "#{col}_hash"
    prefix_col = "#{col}_prefix"

    %Postgrex.Result{rows: rows} =
      Repo.query!("SELECT id, #{col} FROM #{table} WHERE #{col} IS NOT NULL")

    Enum.each(rows, fn [id, plaintext] ->
      Repo.query!(
        "UPDATE #{table} SET #{hash_col} = $1, #{prefix_col} = $2 WHERE id = $3",
        [TokenHash.hash(plaintext), TokenHash.prefix(plaintext), id]
      )
    end)
  end

  defp drop_plaintext(%{table: table, col: col}) do
    # Drop the index on the hash column we're about to add (in case it
    # was created earlier). The unique constraint on plaintext is
    # implicit-dropped when the column is dropped.
    table_atom = String.to_atom(table)
    col_atom = String.to_atom(col)

    alter table(table_atom) do
      remove col_atom
    end

    # Index the hash column for the equality-lookup auth path. Unique
    # because: HMAC-SHA-256 collisions are non-existent for distinct
    # inputs, and the plaintext was unique on three of the four tables.
    create unique_index(table_atom, [String.to_atom("#{col}_hash")])
  end

  def down, do: raise("HashTokenColumns is irreversible — restore plaintext columns from snapshot.")
end

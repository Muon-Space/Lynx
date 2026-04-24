defmodule Lynx.Repo.Migrations.DedupeUserTeams do
  @moduledoc """
  Clean up duplicate `user_teams` rows + add the unique index that
  should have been there from the start.

  `user_teams` was created without a unique constraint on
  `(user_id, team_id)`. When migration `…000013` merged duplicate-
  email users via `Lynx.Service.UserDeduper`, the re-parent step
  (`UPDATE user_teams SET user_id = winner WHERE user_id = loser`)
  produced two rows per (user, team) pair if both winner and loser
  were in the same team — exactly what happened on prod for
  `Lynx Admins`, where Aron + Karl each had a legacy local row + an
  active SCIM row both in the same admin team.

  Symptom: the team-edit modal showed "Aron Gates ×, Aron Gates ×,
  Karl Nordstrom ×, Karl Nordstrom ×" — one chip per row, two rows
  per user.

  This migration:
    1. Collapses duplicate `(user_id, team_id)` pairs to a single row
       (keeps the row with the lowest `id` — arbitrary but deterministic)
    2. Adds the unique index so duplicates can't recur

  Sister table `user_projects` already has the unique constraint
  (it was created later with the right shape). `users_meta` is left
  alone — it's a free-form key/value store where multiple values per
  key may be intentional.
  """

  use Ecto.Migration

  def up do
    # Keep the lowest-id row per (user_id, team_id), delete the rest.
    # The chosen row is arbitrary but deterministic — for membership
    # bookkeeping the rows are interchangeable (same user, same team).
    repo().query!("""
    DELETE FROM user_teams a
    USING user_teams b
    WHERE a.id > b.id
      AND a.user_id = b.user_id
      AND a.team_id = b.team_id
    """)

    flush()

    create unique_index(:user_teams, [:user_id, :team_id])
  end

  def down do
    drop_if_exists unique_index(:user_teams, [:user_id, :team_id])
    # Pre-existing duplicate rows are NOT recovered; restore from
    # snapshot if needed.
  end
end

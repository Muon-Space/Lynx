defmodule LynxWeb.Limits do
  @moduledoc """
  Platform-wide caps for paginated queries called from LiveViews.

  Most "show all" admin views currently load every record up to a hard cap.
  These constants name those caps so they're audit-able and easy to tune.

  Categorized by risk profile:

    * `dropdown_max/0` — used to populate `<select>` options. Anything above
      a few hundred rows here means autocomplete is needed (see
      `Lynx.Context.UserContext.search_users/2` etc.).

    * `child_collection_max/0` — used when listing the children of a single
      parent (envs in a project, projects in a workspace). Bounded by
      org topology in practice; the cap is a safety net, not a UX choice.

    * `serialization_max/0` — used by background-snapshot enumeration. A
      large project with thousands of envs would OOM today; tracked
      separately because the fix is paginated streaming, not autocomplete.
  """

  @doc "Cap for `<select>` option lists (users, teams, projects pickers)."
  def dropdown_max, do: 1_000

  @doc "Cap for child-collection lists (envs in a project, projects in a workspace)."
  def child_collection_max, do: 1_000

  @doc "Cap for snapshot serialization. Whole project tree is read into memory."
  def serialization_max, do: 10_000
end

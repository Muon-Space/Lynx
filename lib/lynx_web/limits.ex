defmodule LynxWeb.Limits do
  @moduledoc """
  Platform-wide caps for paginated queries called from LiveViews. These
  constants name the caps so they're audit-able and easy to tune.

    * `child_collection_max/0` — used when listing the children of a single
      parent (envs in a project, projects in a workspace). Bounded by
      org topology in practice; the cap is a safety net, not a UX choice.

    * `serialization_max/0` — used by background-snapshot enumeration. A
      large project with thousands of envs would OOM today; tracked
      separately because the fix is paginated streaming, not autocomplete.

  The former `dropdown_max/0` was retired once `<.combobox>` (autocomplete)
  replaced eager-loaded `<select>` option lists. See `search_users/2`,
  `search_teams/2`, etc. on the corresponding contexts.
  """

  @doc "Cap for child-collection lists (envs in a project, projects in a workspace)."
  def child_collection_max, do: 1_000

  @doc "Cap for snapshot serialization. Whole project tree is read into memory."
  def serialization_max, do: 10_000
end

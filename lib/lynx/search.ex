defmodule Lynx.Search do
  @moduledoc """
  Helpers for the autocomplete `search_*` functions on each context.

  Centralizes LIKE-pattern escaping so a user-supplied substring like
  `100%` doesn't turn the `%` into a wildcard (which would make every
  query match every row).
  """

  @doc """
  Escape PostgreSQL LIKE/ILIKE wildcards in a user-supplied query so
  the result can be safely interpolated as a substring pattern.
  """
  @spec escape_like(String.t()) :: String.t()
  def escape_like(query) when is_binary(query) do
    query
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end

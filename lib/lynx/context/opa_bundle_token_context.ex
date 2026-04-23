defmodule Lynx.Context.OPABundleTokenContext do
  @moduledoc """
  Service tokens for the OPA bundle endpoint. Mint-once / show-once UX
  mirrors `SCIMTokenContext`, but the two are deliberately separate:
  bundle tokens grant nothing except the bundle endpoint, and don't go
  through `RoleContext`.

  The Helm-managed token is checked separately via env var by
  `OPABundleAuthMiddleware`; only operator-managed tokens land here.
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.OPABundleToken

  def new_token(attrs \\ %{}) do
    %{
      uuid: Map.get(attrs, :uuid, Ecto.UUID.generate()),
      name: attrs[:name],
      token: Map.get(attrs, :token, generate_random_token()),
      is_active: Map.get(attrs, :is_active, true)
    }
  end

  def create_token(attrs) do
    %OPABundleToken{}
    |> OPABundleToken.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Generate a token. Returns `{:ok, %{uuid, name, token}}` with the
  plaintext token (shown once to the caller).
  """
  def generate_token(name) do
    attrs = new_token(%{name: name})

    case create_token(attrs) do
      {:ok, record} ->
        {:ok, %{uuid: record.uuid, name: record.name, token: attrs.token}}

      {:error, changeset} ->
        msg =
          changeset.errors
          |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)
          |> Enum.at(0)

        {:error, msg}
    end
  end

  @doc """
  List tokens for the Settings UI — token value is masked, so the caller
  never sees the raw secret after creation.
  """
  def list_tokens do
    from(t in OPABundleToken, order_by: [desc: t.inserted_at])
    |> Repo.all()
    |> Enum.map(fn t ->
      %{
        uuid: t.uuid,
        name: t.name,
        token_prefix: mask_token(t.token),
        is_active: t.is_active,
        last_used_at: t.last_used_at,
        inserted_at: t.inserted_at
      }
    end)
  end

  def get_token_by_uuid(uuid) do
    from(t in OPABundleToken, where: t.uuid == ^uuid) |> Repo.one()
  end

  @doc """
  Look up an active token by its raw value. Bumps `last_used_at` as a
  side effect when found. Returns the record or nil.
  """
  def validate_token(token) when is_binary(token) do
    case from(t in OPABundleToken, where: t.token == ^token and t.is_active == true)
         |> Repo.one() do
      nil ->
        nil

      record ->
        touch_last_used(record)
        record
    end
  end

  def validate_token(_), do: nil

  def revoke_token_by_uuid(uuid) do
    case get_token_by_uuid(uuid) do
      nil ->
        {:not_found, "Token not found"}

      token ->
        token
        |> OPABundleToken.changeset(%{is_active: false})
        |> Repo.update()

        {:ok, "Token revoked"}
    end
  end

  def delete_token_by_uuid(uuid) do
    case get_token_by_uuid(uuid) do
      nil ->
        {:not_found, "Token not found"}

      token ->
        case Repo.delete(token) do
          {:ok, _} -> {:ok, "Token deleted"}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  # OPA polls the bundle endpoint every ~10s per replica, so a synchronous
  # `last_used_at` UPDATE on every request would translate to constant write
  # amplification on a single row under multi-replica deploys. Skip the
  # write if we already updated within the last minute — operator UX (the
  # Settings page shows "last used 2 min ago" granularity) is unaffected.
  @last_used_debounce_seconds 60

  defp touch_last_used(record) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    if needs_touch?(record.last_used_at, now) do
      record
      |> OPABundleToken.changeset(%{last_used_at: now})
      |> Repo.update()
    end
  end

  defp needs_touch?(nil, _now), do: true

  defp needs_touch?(%DateTime{} = last, now),
    do: DateTime.diff(now, last, :second) >= @last_used_debounce_seconds

  defp needs_touch?(%NaiveDateTime{} = last, now),
    do:
      NaiveDateTime.diff(now |> DateTime.to_naive(), last, :second) >= @last_used_debounce_seconds

  defp generate_random_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp mask_token(token) when is_binary(token) and byte_size(token) > 8,
    do: String.slice(token, 0, 8) <> "..."

  defp mask_token(token), do: token
end

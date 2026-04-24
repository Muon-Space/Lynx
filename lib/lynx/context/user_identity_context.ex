defmodule Lynx.Context.UserIdentityContext do
  @moduledoc """
  Lookup + linking for the `user_identities` table. The single point of
  truth for "given an IdP-asserted identity, which Lynx user is it?"

  Auth flows (SCIM, SAML, OIDC, local password) all converge on
  `find_or_link/4` for the create-or-merge decision: if no identity
  matches by `(provider, provider_uid)`, fall back to email; if a user
  with that email exists, link a new identity row to them (the
  "merge" — the same human now has multiple ways to log in).
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.{User, UserIdentity}

  @doc """
  Look up the canonical user for a given (provider, provider_uid). Nil
  if no identity matches.
  """
  def get_user_by_identity(_provider, nil), do: nil
  def get_user_by_identity(_provider, ""), do: nil

  def get_user_by_identity(provider, provider_uid)
      when is_binary(provider) and is_binary(provider_uid) do
    from(u in User,
      join: i in UserIdentity,
      on: i.user_id == u.id,
      where: i.provider == ^provider and i.provider_uid == ^provider_uid,
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Get the identity row for a (provider, provider_uid) pair.
  """
  def get_identity(provider, provider_uid)
      when is_binary(provider) and is_binary(provider_uid) do
    from(i in UserIdentity,
      where: i.provider == ^provider and i.provider_uid == ^provider_uid,
      limit: 1
    )
    |> Repo.one()
  end

  def get_identity(_, _), do: nil

  @doc """
  All identities linked to a user, newest-first. Used by the Profile
  page's "Linked accounts" section.
  """
  def list_identities_for_user(user_id) do
    from(i in UserIdentity,
      where: i.user_id == ^user_id,
      order_by: [desc: i.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Link an identity to an existing user. Idempotent on
  (user_id, provider) — re-linking the same provider for a user
  refreshes `provider_uid` + `email` + `name` + `last_seen_at`
  rather than inserting a duplicate. This is the "merge" point
  for the find-or-link contract.

  `name` is the per-identity snapshot — what this IdP claimed for
  the display name on this link. The canonical `users.name` is
  separate; only privileged callers (SCIM) update it.
  """
  def link_identity(%User{} = user, provider, provider_uid, email, name \\ nil) do
    case Repo.get_by(UserIdentity, user_id: user.id, provider: provider) do
      nil ->
        attrs = %{
          uuid: Ecto.UUID.generate(),
          user_id: user.id,
          provider: provider,
          provider_uid: provider_uid,
          email: email,
          name: name,
          last_seen_at: now()
        }

        %UserIdentity{}
        |> UserIdentity.changeset(attrs)
        |> Repo.insert()

      existing ->
        # Preserve the snapshot if this refresh didn't carry one — an
        # IdP omitting the claim shouldn't blank the previously-stored
        # value.
        refresh_attrs = %{
          provider_uid: provider_uid,
          email: email || existing.email,
          name: name || existing.name,
          last_seen_at: now()
        }

        existing
        |> UserIdentity.changeset(refresh_attrs)
        |> Repo.update()
    end
  end

  @doc """
  Update `last_seen_at` for an identity. Cheap touch — no other fields
  change. Returns `:ok` regardless of whether the identity exists, so
  callers don't have to branch (a missing identity here is a state
  the auth flow has already handled).
  """
  def touch(provider, provider_uid) when is_binary(provider) and is_binary(provider_uid) do
    case get_identity(provider, provider_uid) do
      nil ->
        :ok

      identity ->
        identity
        |> UserIdentity.changeset(%{last_seen_at: now()})
        |> Repo.update()

        :ok
    end
  end

  def touch(_, _), do: :ok

  @doc """
  Delete a linked identity from a user. Refuses to remove the user's
  last identity — they'd be locked out with no way back in. Returns
  `:ok` on success, `{:error, :would_lock_out}` on the last-identity
  guard.
  """
  def delete_identity(%UserIdentity{} = identity) do
    others_count =
      from(i in UserIdentity,
        where: i.user_id == ^identity.user_id and i.id != ^identity.id,
        select: count(i.id)
      )
      |> Repo.one()

    cond do
      others_count == 0 ->
        {:error, :would_lock_out}

      true ->
        Repo.delete(identity)
        :ok
    end
  end

  @doc """
  Find an existing user via identity OR email, OR create a new one.
  This is the single entry point that all SSO/SCIM provisioning
  flows should call — it handles the merge case (email match → link
  new identity to existing user) so duplicate users can't recur.

  `name` is the per-identity name snapshot from the IdP claim.
  Stored on the identity row only — callers decide whether to also
  update the canonical `users.name` (SCIM does, drive-by SSO doesn't).

  Returns:
    * `{:ok, user, :existing_via_identity}` — identity hit, user already had this provider linked
    * `{:ok, user, :merged_by_email}` — email matched an existing user; new identity linked to them
    * `{:ok, user, :created}` — no match anywhere; brand-new user + first identity
    * `{:error, reason}` — DB-level failure

  `create_user_fn` is invoked only on the `:created` branch — callers
  pass the function that knows how to mint a user with whatever
  defaults their provisioning path needs (e.g. `verified: true` for
  SCIM, role from SAML attributes, etc.).
  """
  def find_or_link(provider, provider_uid, email, name, create_user_fn)
      when is_function(create_user_fn, 0) do
    case get_user_by_identity(provider, provider_uid) do
      %User{} = user ->
        # Refresh `last_seen_at` + email + name snapshot.
        link_identity(user, provider, provider_uid, email, name)
        {:ok, user, :existing_via_identity}

      nil ->
        find_by_email_or_create(provider, provider_uid, email, name, create_user_fn)
    end
  end

  defp find_by_email_or_create(provider, provider_uid, email, name, create_user_fn) do
    case email && Lynx.Context.UserContext.get_user_by_email(email) do
      %User{} = user ->
        # MERGE path: same human, new login method. Link this identity
        # to the existing user so future logins via this IdP resolve
        # back to the same canonical account.
        link_identity(user, provider, provider_uid, email, name)
        {:ok, user, :merged_by_email}

      _ ->
        case create_user_fn.() do
          {:ok, %User{} = user} ->
            link_identity(user, provider, provider_uid, email, name)
            {:ok, user, :created}

          {:error, _} = err ->
            err

          {:not_found, msg} ->
            {:error, msg}
        end
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end

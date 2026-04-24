defmodule Lynx.Model.UserIdentity do
  @moduledoc """
  One row per (user × login method). Lets a single canonical user link
  multiple identity providers — see migration `…000013` and PR for the
  rationale (previous design conflated identity-of-user with how-they-
  last-authenticated, causing duplicate user rows when the same human
  signed in via SAML and SCIM with different external IDs).

  ## Provider values

    * `"local"` — password auth (`provider_uid` is nil; the credential
      is `users.password_hash`)
    * `"scim"` — SCIM-provisioned identity (`provider_uid` is the
      IdP's stable user ID, e.g. Okta's user UID)
    * `"saml"` — SAML SSO (`provider_uid` is the SAML NameID, often
      the user's email when NameID format is emailAddress)
    * `"oidc"` — OIDC SSO (`provider_uid` is the OIDC `sub` claim)

  ## Email field

  Snapshot of the email this identity presented when first linked.
  IdPs change emails over time (org renames, marriage, etc.); storing
  the snapshot lets operators audit which email a given identity
  originally claimed without losing the data when the user's
  canonical email changes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @valid_providers ["local", "scim", "saml", "oidc"]

  schema "user_identities" do
    field :uuid, Ecto.UUID
    field :user_id, :id
    field :provider, :string
    field :provider_uid, :string
    field :email, :string
    field :last_seen_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:uuid, :user_id, :provider, :provider_uid, :email, :last_seen_at])
    |> validate_required([:uuid, :user_id, :provider])
    |> validate_inclusion(:provider, @valid_providers)
    |> validate_provider_uid_for_remote()
    |> unique_constraint([:provider, :provider_uid],
      name: :user_identities_provider_uid_idx,
      message: "another user is already linked to this identity"
    )
    |> unique_constraint([:user_id, :provider],
      name: :user_identities_user_id_provider_index,
      message: "this user already has an identity for this provider"
    )
  end

  # `local` is the only provider where `provider_uid` may be nil
  # (the password hash on the user row is the credential). Every
  # remote IdP must supply a stable identifier.
  defp validate_provider_uid_for_remote(changeset) do
    case get_field(changeset, :provider) do
      "local" ->
        changeset

      provider when provider in ["scim", "saml", "oidc"] ->
        validate_required(changeset, [:provider_uid])

      _ ->
        changeset
    end
  end

  def valid_providers, do: @valid_providers
end

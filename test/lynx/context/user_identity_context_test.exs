defmodule Lynx.Context.UserIdentityContextTest do
  @moduledoc """
  Pinning the contract of the identity-linking layer that lets a single
  canonical user link multiple IdPs (the "merge" pattern that prevents
  duplicate user rows when the same human signs in via SAML, OIDC,
  SCIM, or password).
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.{UserContext, UserIdentityContext}

  setup do
    mark_installed()
    :ok
  end

  describe "find_or_link/4" do
    test "creates user + identity on first sight (no email match, no identity match)" do
      create_fn = fn ->
        UserContext.create_sso_user(%{email: "fresh@example.com", name: "Fresh User"})
      end

      assert {:ok, user, :created} =
               UserIdentityContext.find_or_link("scim", "okta-uid-001", "fresh@example.com", create_fn)

      assert user.email == "fresh@example.com"

      identity = UserIdentityContext.get_identity("scim", "okta-uid-001")
      assert identity.user_id == user.id
      assert identity.email == "fresh@example.com"
    end

    test "returns the existing user when the identity already matches" do
      user = create_user(%{email: "known@example.com"})
      {:ok, _} = UserIdentityContext.link_identity(user, "saml", "saml-nameid-known", "known@example.com")

      # `create_fn` should NOT be called — assertion via raise.
      create_fn = fn -> raise "create_fn should not have been invoked" end

      assert {:ok, returned, :existing_via_identity} =
               UserIdentityContext.find_or_link("saml", "saml-nameid-known", "known@example.com", create_fn)

      assert returned.id == user.id
    end

    test "merges by email — links the new identity to the existing user (no duplicate row)" do
      # Simulates: user exists from password signup, now logs in via
      # SAML for the first time. Old design created a second user row;
      # new design links the SAML identity to the existing user.
      user = create_user(%{email: "merge@example.com"})

      create_fn = fn -> raise "create_fn should not have been invoked when email matches" end

      assert {:ok, returned, :merged_by_email} =
               UserIdentityContext.find_or_link(
                 "saml",
                 "saml-nameid-merge",
                 "merge@example.com",
                 create_fn
               )

      assert returned.id == user.id

      # SAML identity is now linked to the same user.
      identity = UserIdentityContext.get_identity("saml", "saml-nameid-merge")
      assert identity.user_id == user.id

      # Single users row, not a duplicate.
      import Ecto.Query
      count = Lynx.Repo.aggregate(from(u in Lynx.Model.User, where: u.email == "merge@example.com"), :count)
      assert count == 1
    end

    test "the same human can have identities on multiple providers (SAML + SCIM + local)" do
      user = create_user(%{email: "multi@example.com"})
      no_create = fn -> raise "should not create — email match must merge" end

      {:ok, _} = UserIdentityContext.link_identity(user, "local", nil, "multi@example.com")

      assert {:ok, scim_user, :merged_by_email} =
               UserIdentityContext.find_or_link(
                 "scim",
                 "okta-uid-multi",
                 "multi@example.com",
                 no_create
               )

      assert scim_user.id == user.id

      assert {:ok, saml_user, :merged_by_email} =
               UserIdentityContext.find_or_link(
                 "saml",
                 "saml-nameid-multi",
                 "multi@example.com",
                 no_create
               )

      assert saml_user.id == user.id

      providers =
        UserIdentityContext.list_identities_for_user(user.id)
        |> Enum.map(& &1.provider)
        |> Enum.sort()

      assert providers == ["local", "saml", "scim"]
    end
  end

  describe "link_identity/4" do
    test "is idempotent on (user_id, provider) — refreshes provider_uid + email" do
      user = create_user(%{email: "idem@example.com"})

      {:ok, _first} =
        UserIdentityContext.link_identity(user, "scim", "old-okta-uid", "idem@example.com")

      # Same provider + user but new provider_uid → updates in place
      # (e.g. Okta migrated the user to a new internal ID).
      {:ok, second} =
        UserIdentityContext.link_identity(user, "scim", "new-okta-uid", "idem-renamed@example.com")

      assert second.provider_uid == "new-okta-uid"
      assert second.email == "idem-renamed@example.com"

      # Old provider_uid lookup no longer hits.
      assert UserIdentityContext.get_identity("scim", "old-okta-uid") == nil
      assert UserIdentityContext.get_identity("scim", "new-okta-uid").user_id == user.id
    end
  end

  describe "delete_identity/1" do
    test "refuses to delete the user's last identity (would lock them out)" do
      user = create_user(%{email: "lockout@example.com"})

      {:ok, only_identity} =
        UserIdentityContext.link_identity(user, "local", nil, "lockout@example.com")

      assert {:error, :would_lock_out} = UserIdentityContext.delete_identity(only_identity)

      # Identity still there.
      assert UserIdentityContext.list_identities_for_user(user.id) |> length() == 1
    end

    test "deletes when at least one other identity remains" do
      user = create_user(%{email: "unlink@example.com"})

      {:ok, _local} = UserIdentityContext.link_identity(user, "local", nil, "unlink@example.com")
      {:ok, scim} = UserIdentityContext.link_identity(user, "scim", "okta-uid-unlink", "unlink@example.com")

      assert :ok = UserIdentityContext.delete_identity(scim)

      remaining = UserIdentityContext.list_identities_for_user(user.id)
      assert length(remaining) == 1
      assert hd(remaining).provider == "local"
    end
  end

  describe "get_user_by_identity/2" do
    test "returns nil for nil/empty provider_uid" do
      assert UserIdentityContext.get_user_by_identity("scim", nil) == nil
      assert UserIdentityContext.get_user_by_identity("scim", "") == nil
    end

    test "returns nil when no identity matches" do
      assert UserIdentityContext.get_user_by_identity("scim", "nonexistent") == nil
    end
  end
end

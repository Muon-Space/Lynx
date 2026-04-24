# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.SCIMControllerTest do
  use LynxWeb.ConnCase

  alias Lynx.Context.SCIMTokenContext
  alias Lynx.Service.Settings

  setup %{conn: conn} do
    # Install the app first
    params = %{
      app_name: "Lynx",
      app_url: "https://lynx.com",
      app_email: "hello@lynx.com",
      admin_name: "John Doe",
      admin_email: "john@example.com",
      admin_password: "password123"
    }

    post(conn, "/action/install", params)

    # Enable SCIM and generate a token in the DB
    Settings.upsert_config("scim_enabled", "true")
    {:ok, token_result} = SCIMTokenContext.generate_token("test token")

    on_exit(fn ->
      Settings.upsert_config("scim_enabled", "false")
    end)

    {:ok, conn: conn, scim_token: token_result.token}
  end

  defp scim_conn(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/scim+json")
  end

  # -- Auth --

  describe "SCIM authentication" do
    test "rejects request without bearer token", %{conn: conn} do
      conn = get(conn, "/scim/v2/Users")
      assert json_response(conn, 401)["status"] == "401"
    end

    test "rejects request with invalid bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-token")
        |> get("/scim/v2/Users")

      assert json_response(conn, 401)["status"] == "401"
    end

    test "returns 404 when SCIM is disabled", %{conn: conn, scim_token: scim_token} do
      Settings.upsert_config("scim_enabled", "false")

      conn =
        conn
        |> scim_conn(scim_token)
        |> get("/scim/v2/Users")

      assert json_response(conn, 404)["status"] == "404"
    end
  end

  # -- Discovery --

  describe "SCIM discovery" do
    test "GET /ServiceProviderConfig", %{conn: conn, scim_token: scim_token} do
      conn =
        conn
        |> scim_conn(scim_token)
        |> get("/scim/v2/ServiceProviderConfig")

      body = json_response(conn, 200)
      assert body["patch"]["supported"] == true
      assert body["filter"]["supported"] == true
    end

    test "GET /ResourceTypes", %{conn: conn, scim_token: scim_token} do
      conn =
        conn
        |> scim_conn(scim_token)
        |> get("/scim/v2/ResourceTypes")

      body = json_response(conn, 200)
      assert is_list(body)
      assert length(body) == 2
    end

    test "GET /Schemas", %{conn: conn, scim_token: scim_token} do
      conn =
        conn
        |> scim_conn(scim_token)
        |> get("/scim/v2/Schemas")

      body = json_response(conn, 200)
      assert is_list(body)
      assert length(body) == 2
    end
  end

  # -- Users --

  describe "SCIM Users" do
    test "POST /Users creates a user", %{conn: conn, scim_token: scim_token} do
      body = %{
        "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:User"],
        "userName" => "scim_create@example.com",
        "name" => %{"givenName" => "SCIM", "familyName" => "Create"},
        "externalId" => "scim-ctrl-001",
        "active" => true
      }

      conn =
        conn
        |> scim_conn(scim_token)
        |> post("/scim/v2/Users", body)

      response = json_response(conn, 201)
      assert response["userName"] == "scim_create@example.com"
      assert response["name"]["formatted"] == "SCIM Create"
      assert response["active"] == true
      assert response["id"] != nil
      assert response["meta"]["resourceType"] == "User"
    end

    test "GET /Users lists users", %{conn: conn, scim_token: scim_token} do
      # Create a user first
      conn
      |> scim_conn(scim_token)
      |> post("/scim/v2/Users", %{
        "userName" => "scim_list@example.com",
        "name" => %{"formatted" => "List User"},
        "externalId" => "scim-ctrl-list"
      })

      conn =
        build_conn()
        |> scim_conn(scim_token)
        |> get("/scim/v2/Users")

      body = json_response(conn, 200)
      assert body["totalResults"] >= 1
      assert is_list(body["Resources"])
    end

    test "GET /Users with filter", %{conn: conn, scim_token: scim_token} do
      conn
      |> scim_conn(scim_token)
      |> post("/scim/v2/Users", %{
        "userName" => "scim_filtered@example.com",
        "name" => %{"formatted" => "Filtered"},
        "externalId" => "scim-ctrl-filtered"
      })

      conn =
        build_conn()
        |> scim_conn(scim_token)
        |> get("/scim/v2/Users", %{"filter" => "userName eq \"scim_filtered@example.com\""})

      body = json_response(conn, 200)
      resources = body["Resources"]
      assert length(resources) == 1
      assert hd(resources)["userName"] == "scim_filtered@example.com"
    end

    test "GET /Users/:id returns a user", %{conn: conn, scim_token: scim_token} do
      create_conn =
        conn
        |> scim_conn(scim_token)
        |> post("/scim/v2/Users", %{
          "userName" => "scim_getone@example.com",
          "name" => %{"formatted" => "Get One"},
          "externalId" => "scim-ctrl-getone"
        })

      user_id = json_response(create_conn, 201)["id"]

      conn =
        build_conn()
        |> scim_conn(scim_token)
        |> get("/scim/v2/Users/#{user_id}")

      body = json_response(conn, 200)
      assert body["id"] == user_id
      assert body["userName"] == "scim_getone@example.com"
    end

    test "GET /Users/:id returns 404 for missing user", %{conn: conn, scim_token: scim_token} do
      conn =
        conn
        |> scim_conn(scim_token)
        |> get("/scim/v2/Users/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)["status"] == "404"
    end

    test "PATCH /Users/:id deactivates a user", %{conn: conn, scim_token: scim_token} do
      create_conn =
        conn
        |> scim_conn(scim_token)
        |> post("/scim/v2/Users", %{
          "userName" => "scim_patch@example.com",
          "name" => %{"formatted" => "Patch User"},
          "externalId" => "scim-ctrl-patch"
        })

      user_id = json_response(create_conn, 201)["id"]

      conn =
        build_conn()
        |> scim_conn(scim_token)
        |> patch("/scim/v2/Users/#{user_id}", %{
          "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
          "Operations" => [%{"op" => "replace", "value" => %{"active" => false}}]
        })

      body = json_response(conn, 200)
      assert body["active"] == false
    end

    test "DELETE /Users/:id deactivates a user", %{conn: conn, scim_token: scim_token} do
      create_conn =
        conn
        |> scim_conn(scim_token)
        |> post("/scim/v2/Users", %{
          "userName" => "scim_del@example.com",
          "name" => %{"formatted" => "Delete User"},
          "externalId" => "scim-ctrl-del"
        })

      user_id = json_response(create_conn, 201)["id"]

      conn =
        build_conn()
        |> scim_conn(scim_token)
        |> delete("/scim/v2/Users/#{user_id}")

      assert response(conn, 204)
    end
  end

  # -- Reactivate cycle (regression coverage) --

  # Reproducer for the reported regression: SCIM-provision a user,
  # SCIM-deactivate them, then SCIM-reactivate. The user must end up
  # `is_active: true` in the DB and the GET /Users response must
  # report `active: true`. Several flavours because Okta uses a mix
  # of these depending on how the integration is wired.
  defp create_cycle_user(conn, scim_token, suffix) do
    create_conn =
      conn
      |> scim_conn(scim_token)
      |> post("/scim/v2/Users", %{
        "userName" => "scim_cycle_#{suffix}@example.com",
        "name" => %{"formatted" => "Cycle User"},
        "externalId" => "scim-cycle-#{suffix}"
      })

    body = json_response(create_conn, 201)
    %{id: body["id"], external_id: "scim-cycle-#{suffix}"}
  end

  defp patch_active(scim_token, user_id, active) do
    build_conn()
    |> scim_conn(scim_token)
    |> patch("/scim/v2/Users/#{user_id}", %{
      "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
      "Operations" => [%{"op" => "replace", "value" => %{"active" => active}}]
    })
  end

  defp put_user(scim_token, user_id, payload) do
    build_conn()
    |> scim_conn(scim_token)
    |> put("/scim/v2/Users/#{user_id}", payload)
  end

  describe "deactivate → reactivate round-trip" do
    test "PATCH active=false → PATCH active=true round-trips back to active",
         %{conn: conn, scim_token: scim_token} do
      %{id: user_id} = create_cycle_user(conn, scim_token, "patch-patch")

      deactivate = patch_active(scim_token, user_id, false)
      assert json_response(deactivate, 200)["active"] == false

      reactivate = patch_active(scim_token, user_id, true)
      assert json_response(reactivate, 200)["active"] == true

      get_resp =
        build_conn()
        |> scim_conn(scim_token)
        |> get("/scim/v2/Users/#{user_id}")

      assert json_response(get_resp, 200)["active"] == true
    end

    test "PATCH active=false → PUT with active=true round-trips back to active",
         %{conn: conn, scim_token: scim_token} do
      %{id: user_id} = create_cycle_user(conn, scim_token, "patch-put")

      deactivate = patch_active(scim_token, user_id, false)
      assert json_response(deactivate, 200)["active"] == false

      reactivate =
        put_user(scim_token, user_id, %{
          "userName" => "scim_cycle_patch-put@example.com",
          "name" => %{"formatted" => "Cycle User"},
          "externalId" => "scim-cycle-patch-put",
          "active" => true
        })

      assert json_response(reactivate, 200)["active"] == true
    end

    test "DELETE → POST same externalId reactivates (Okta's typical reactivate path)",
         %{conn: conn, scim_token: scim_token} do
      # Okta often handles "reactivate" by re-pushing the user via
      # POST with the same externalId rather than PATCH. Lynx's
      # `SCIM.create_user/1` routes that to `update_user` when the
      # external_id matches.
      %{id: user_id, external_id: ext_id} = create_cycle_user(conn, scim_token, "delete-post")

      delete_resp =
        build_conn()
        |> scim_conn(scim_token)
        |> delete("/scim/v2/Users/#{user_id}")

      assert response(delete_resp, 204)

      repost =
        build_conn()
        |> scim_conn(scim_token)
        |> post("/scim/v2/Users", %{
          "userName" => "scim_cycle_delete-post@example.com",
          "name" => %{"formatted" => "Cycle User"},
          "externalId" => ext_id,
          "active" => true
        })

      # The controller always returns 201 from POST /Users, so we can't
      # distinguish create-vs-update by status. The real signal is the
      # returned `id` — if it matches the original UUID, the existing
      # row was reactivated; if it differs, a new user was created
      # (which would orphan the old row + duplicate the email).
      body = json_response(repost, 201)
      assert body["id"] == user_id, "Expected the same UUID (#{user_id}) — a different one means a new user was created instead of reactivating the existing row"
      assert body["active"] == true
    end

    test "PATCH with capital-R 'Replace' op (Okta-style) deactivates correctly (SCIM spec: op is case-insensitive)",
         %{conn: conn, scim_token: scim_token} do
      # RFC 7644 §3.5.2: the `op` value MUST be matched case-insensitively.
      # Okta sends "op":"Replace" (capital R) by default. If Lynx's
      # pattern matching only accepts lowercase, the operation is
      # silently dropped — the user stays in whatever state they
      # were in before.
      %{id: user_id} = create_cycle_user(conn, scim_token, "case-deactivate")

      conn =
        build_conn()
        |> scim_conn(scim_token)
        |> patch("/scim/v2/Users/#{user_id}", %{
          "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
          "Operations" => [%{"op" => "Replace", "value" => %{"active" => false}}]
        })

      assert json_response(conn, 200)["active"] == false
    end

    test "PATCH with capital-R 'Replace' op reactivates correctly (Okta's actual reactivate request)",
         %{conn: conn, scim_token: scim_token} do
      %{id: user_id} = create_cycle_user(conn, scim_token, "case-reactivate")

      # Deactivate via lowercase first (we know that works).
      _ = patch_active(scim_token, user_id, false)

      # Reactivate via capital-R "Replace" — this is what Okta sends.
      reactivate =
        build_conn()
        |> scim_conn(scim_token)
        |> patch("/scim/v2/Users/#{user_id}", %{
          "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
          "Operations" => [%{"op" => "Replace", "path" => "active", "value" => true}]
        })

      assert json_response(reactivate, 200)["active"] == true
    end

    test "PUT that omits active does NOT silently flip a deactivated user back",
         %{conn: conn, scim_token: scim_token} do
      # Negative pin: a PUT that omits `active` must preserve the
      # current value (not default to true). Otherwise tools that
      # send a name change without `active` would silently reactivate.
      %{id: user_id} = create_cycle_user(conn, scim_token, "preserve")

      deactivate = patch_active(scim_token, user_id, false)
      assert json_response(deactivate, 200)["active"] == false

      unrelated_update =
        put_user(scim_token, user_id, %{
          "userName" => "scim_cycle_preserve@example.com",
          "name" => %{"formatted" => "Renamed"},
          "externalId" => "scim-cycle-preserve"
        })

      assert json_response(unrelated_update, 200)["active"] == false
    end
  end

  # -- Groups --

  describe "SCIM Groups" do
    test "POST /Groups creates a group", %{conn: conn, scim_token: scim_token} do
      conn =
        conn
        |> scim_conn(scim_token)
        |> post("/scim/v2/Groups", %{
          "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:Group"],
          "displayName" => "Engineering",
          "externalId" => "scim-grp-ctrl-001"
        })

      body = json_response(conn, 201)
      assert body["displayName"] == "Engineering"
      assert body["id"] != nil
      assert body["meta"]["resourceType"] == "Group"
    end

    test "GET /Groups lists groups", %{conn: conn, scim_token: scim_token} do
      conn
      |> scim_conn(scim_token)
      |> post("/scim/v2/Groups", %{
        "displayName" => "List Group",
        "externalId" => "scim-grp-ctrl-list"
      })

      conn =
        build_conn()
        |> scim_conn(scim_token)
        |> get("/scim/v2/Groups")

      body = json_response(conn, 200)
      assert body["totalResults"] >= 1
    end

    test "DELETE /Groups/:id deletes a group", %{conn: conn, scim_token: scim_token} do
      create_conn =
        conn
        |> scim_conn(scim_token)
        |> post("/scim/v2/Groups", %{
          "displayName" => "Delete Group",
          "externalId" => "scim-grp-ctrl-del"
        })

      group_id = json_response(create_conn, 201)["id"]

      conn =
        build_conn()
        |> scim_conn(scim_token)
        |> delete("/scim/v2/Groups/#{group_id}")

      assert response(conn, 204)

      # Verify it's gone
      conn =
        build_conn()
        |> scim_conn(scim_token)
        |> get("/scim/v2/Groups/#{group_id}")

      assert json_response(conn, 404)
    end
  end
end

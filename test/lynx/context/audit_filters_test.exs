defmodule Lynx.Context.AuditFiltersTest do
  @moduledoc """
  Coverage for the new filter options on `AuditContext.list_events/1` and
  the CSV streaming export. Existing action / resource_type / actor_id /
  pagination filters are exercised by `LynxWeb.AuditLiveTest`.
  """
  use LynxWeb.LiveCase

  alias Lynx.Context.{AuditContext, UserContext}
  alias Lynx.Repo

  setup do
    mark_installed()

    alice =
      create_user(%{name: "Alice", email: "alice@example.com", password: "password123"})

    bob = create_user(%{name: "Bob", email: "bob@example.com", password: "password123"})

    {:ok, alice: alice, bob: bob}
  end

  describe ":resource_id" do
    test "filters to events for the given resource id", %{alice: alice} do
      AuditContext.log_user(alice, "created", "project", "p-keep", "Keep")
      AuditContext.log_user(alice, "created", "project", "p-drop", "Drop")

      {events, total} = AuditContext.list_events(%{resource_id: "p-keep"})

      assert total == 1
      assert Enum.map(events, & &1.resource_id) == ["p-keep"]
    end
  end

  describe ":actor_email" do
    test "ilike-substring matches against the actor's email", %{alice: alice, bob: bob} do
      AuditContext.log_user(alice, "created", "project", "p1", "Alice's project")
      AuditContext.log_user(bob, "created", "project", "p2", "Bob's project")

      {events, _} = AuditContext.list_events(%{actor_email: "alice@"})
      assert Enum.map(events, & &1.resource_name) == ["Alice's project"]

      {events, _} = AuditContext.list_events(%{actor_email: "example.com"})
      assert length(events) == 2
    end

    test "escapes LIKE wildcards in the search term", %{alice: alice} do
      AuditContext.log_user(alice, "created", "project", "p1", "x")

      # `%` would match everything if not escaped — here it shouldn't match
      # alice's literal email which has no `%` in it.
      assert AuditContext.list_events(%{actor_email: "%"}) == {[], 0}
    end
  end

  describe ":date_from / :date_to" do
    test "filters by inserted_at range", %{alice: alice} do
      AuditContext.log_user(alice, "created", "project", "p1", "in range")

      # Event inserted just now → falls inside (yesterday, tomorrow).
      from = DateTime.add(DateTime.utc_now(), -86_400, :second)
      to = DateTime.add(DateTime.utc_now(), 86_400, :second)

      {events, _} = AuditContext.list_events(%{date_from: from, date_to: to})
      assert length(events) >= 1

      # Strictly past `to` — empty.
      future_from = DateTime.add(DateTime.utc_now(), 86_400, :second)
      assert AuditContext.list_events(%{date_from: future_from}) == {[], 0}
    end
  end

  describe "stream_events_csv/1" do
    test "produces a CSV header + one row per event", %{alice: alice} do
      AuditContext.log_user(alice, "created", "project", "p1", "First")
      AuditContext.log_user(alice, "deleted", "project", "p1", "First")

      csv = export_to_string(%{})

      lines = String.split(String.trim_trailing(csv, "\r\n"), "\r\n", trim: true)
      assert hd(lines) =~ "id,action,resource_type"
      # 2 events + 1 header row
      assert length(lines) == 3
      assert Enum.any?(tl(lines), &String.contains?(&1, "created"))
      assert Enum.any?(tl(lines), &String.contains?(&1, "deleted"))
    end

    test "honors the same filters as list_events", %{alice: alice, bob: bob} do
      AuditContext.log_user(alice, "created", "project", "p1", "Alice")
      AuditContext.log_user(bob, "created", "project", "p2", "Bob")

      csv = export_to_string(%{actor_email: "alice@"})
      assert csv =~ "Alice"
      refute csv =~ "Bob"
    end
  end

  defp export_to_string(opts) do
    {:ok, csv} =
      Repo.transaction(fn ->
        AuditContext.stream_events_csv(opts)
        |> Enum.to_list()
        |> IO.iodata_to_binary()
      end)

    csv
  end

  # Quiet "imported but unused" — we use UserContext implicitly via factories.
  _ = UserContext
end

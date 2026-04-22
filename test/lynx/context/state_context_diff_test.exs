defmodule Lynx.Context.StateContextDiffTest do
  @moduledoc """
  Coverage for `StateContext.diff/2` — the semantic Terraform-state diff
  that powers the state explorer's resource-card view (issue #36).
  """
  use Lynx.DataCase, async: true

  alias Lynx.Context.StateContext

  defp state(resources) do
    Jason.encode!(%{"version" => 4, "serial" => 1, "resources" => resources})
  end

  defp resource(mode, type, name, instances) do
    %{"mode" => mode, "type" => type, "name" => name, "instances" => instances}
  end

  defp instance(attrs, index_key \\ nil) do
    %{"attributes" => attrs}
    |> then(fn i -> if index_key, do: Map.put(i, "index_key", index_key), else: i end)
  end

  describe "diff/2 — resource-level changes" do
    test "added: present in `after`, absent in `before`" do
      before_state = state([])

      after_state =
        state([resource("managed", "aws_iam_role", "ci", [instance(%{"name" => "ci"})])])

      %{added: [a], changed: [], removed: []} = StateContext.diff(before_state, after_state)
      assert a.type == "aws_iam_role"
      assert a.name == "ci"
      assert a.attributes == %{"name" => "ci"}
      assert a.index_key == nil
    end

    test "removed: present in `before`, absent in `after`" do
      before_state =
        state([resource("managed", "aws_security_group", "old", [instance(%{"id" => "sg-1"})])])

      after_state = state([])

      %{added: [], changed: [], removed: [r]} = StateContext.diff(before_state, after_state)
      assert r.type == "aws_security_group"
      assert r.name == "old"
    end

    test "changed: same key, attribute delta" do
      before_state =
        state([
          resource("managed", "aws_vpc", "main", [
            instance(%{"cidr_block" => "10.0.0.0/16", "tags" => %{"env" => "dev"}})
          ])
        ])

      after_state =
        state([
          resource("managed", "aws_vpc", "main", [
            instance(%{"cidr_block" => "10.1.0.0/16", "tags" => %{"env" => "dev"}})
          ])
        ])

      %{added: [], changed: [c], removed: []} = StateContext.diff(before_state, after_state)
      assert c.type == "aws_vpc"
      # Only changed keys appear in the per-attribute list
      assert c.attributes == [{"cidr_block", "10.0.0.0/16", "10.1.0.0/16"}]
      # Full before/after preserved on the entry
      assert c.before["attributes"]["cidr_block"] == "10.0.0.0/16"
      assert c.after["attributes"]["cidr_block"] == "10.1.0.0/16"
    end

    test "no diff when attributes are identical" do
      r =
        resource("managed", "aws_vpc", "main", [
          instance(%{"cidr_block" => "10.0.0.0/16"})
        ])

      assert %{added: [], changed: [], removed: []} =
               StateContext.diff(state([r]), state([r]))
    end
  end

  describe "diff/2 — count/for_each instances (index_key)" do
    test "instances with different index_keys are tracked separately" do
      # Same (mode, type, name) but different index_key → distinct entries
      before_state =
        state([
          resource("managed", "aws_subnet", "private", [
            instance(%{"cidr" => "10.0.1.0/24"}, 0),
            instance(%{"cidr" => "10.0.2.0/24"}, 1)
          ])
        ])

      after_state =
        state([
          resource("managed", "aws_subnet", "private", [
            # index 0 unchanged
            instance(%{"cidr" => "10.0.1.0/24"}, 0),
            # index 1 changed
            instance(%{"cidr" => "10.0.20.0/24"}, 1),
            # index 2 added
            instance(%{"cidr" => "10.0.3.0/24"}, 2)
          ])
        ])

      %{added: added, changed: changed, removed: []} =
        StateContext.diff(before_state, after_state)

      assert length(added) == 1
      assert hd(added).index_key == 2

      assert length(changed) == 1
      assert hd(changed).index_key == 1
      assert hd(changed).attributes == [{"cidr", "10.0.2.0/24", "10.0.20.0/24"}]
    end

    test "for_each (string) index_keys" do
      before_state =
        state([
          resource("managed", "aws_iam_role", "team", [
            instance(%{"name" => "platform"}, "platform"),
            instance(%{"name" => "data"}, "data")
          ])
        ])

      after_state =
        state([
          resource("managed", "aws_iam_role", "team", [
            instance(%{"name" => "platform"}, "platform")
          ])
        ])

      %{added: [], changed: [], removed: [r]} = StateContext.diff(before_state, after_state)
      assert r.index_key == "data"
    end
  end

  describe "diff/2 — attribute-level changes" do
    test "marks keys present on only one side with :absent sentinel" do
      before_state =
        state([resource("managed", "aws_vpc", "main", [instance(%{"a" => 1, "b" => 2})])])

      after_state =
        state([resource("managed", "aws_vpc", "main", [instance(%{"a" => 1, "c" => 3})])])

      %{changed: [c]} = StateContext.diff(before_state, after_state)
      attrs = Enum.into(c.attributes, %{}, fn {k, b, a} -> {k, {b, a}} end)
      assert attrs["b"] == {2, :absent}
      assert attrs["c"] == {:absent, 3}
      refute Map.has_key?(attrs, "a")
    end
  end

  describe "diff/2 — input shapes" do
    test "accepts %State{} structs" do
      s_before = %Lynx.Model.State{value: state([])}
      s_after = %Lynx.Model.State{value: state([resource("managed", "x", "y", [instance(%{})])])}

      assert %{added: [_]} = StateContext.diff(s_before, s_after)
    end

    test "treats nil / empty / non-object as empty state" do
      # Both empty → no diff
      assert %{added: [], changed: [], removed: []} = StateContext.diff(nil, "")
      assert %{added: [], changed: [], removed: []} = StateContext.diff("not json", "{}")

      # One side empty, one populated
      after_state = state([resource("managed", "x", "y", [instance(%{})])])
      assert %{added: [_], changed: [], removed: []} = StateContext.diff(nil, after_state)
      assert %{added: [], changed: [], removed: [_]} = StateContext.diff(after_state, nil)
    end

    test "pre-0.12 state (no resources array) is treated as empty" do
      pre_012 = Jason.encode!(%{"version" => 3, "modules" => []})
      assert %{added: [], changed: [], removed: []} = StateContext.diff(pre_012, pre_012)
    end
  end

  describe "diff/2 — mixed scenario from the issue" do
    test "3 added / 1 changed / 2 removed" do
      before_state =
        state([
          resource("managed", "aws_vpc", "main", [instance(%{"cidr" => "10.0.0.0/16"})]),
          resource("managed", "aws_security_group", "old1", [instance(%{"name" => "sg1"})]),
          resource("managed", "aws_security_group", "old2", [instance(%{"name" => "sg2"})])
        ])

      after_state =
        state([
          # Changed
          resource("managed", "aws_vpc", "main", [instance(%{"cidr" => "10.1.0.0/16"})]),
          # Added
          resource("managed", "aws_iam_role", "r1", [instance(%{"name" => "r1"})]),
          resource("managed", "aws_iam_role", "r2", [instance(%{"name" => "r2"})]),
          resource("managed", "aws_iam_role", "r3", [instance(%{"name" => "r3"})])
        ])

      diff = StateContext.diff(before_state, after_state)
      assert length(diff.added) == 3
      assert length(diff.changed) == 1
      assert length(diff.removed) == 2
    end
  end
end

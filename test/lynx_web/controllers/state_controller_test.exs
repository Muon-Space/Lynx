defmodule LynxWeb.StateControllerTest do
  use LynxWeb.ConnCase

  # NOTE: StateController is not currently mapped to any route in router.ex
  # — Terraform requests are handled by TfController instead. Remove the
  # file (and the controller module) if the legacy controller stays unused.

  describe "module is loadable" do
    test "module exists and exports the action functions" do
      functions = LynxWeb.StateController.__info__(:functions)
      assert Keyword.has_key?(functions, :create)
      assert Keyword.has_key?(functions, :index)
    end
  end
end

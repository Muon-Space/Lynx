defmodule LynxWeb.LockControllerTest do
  use LynxWeb.ConnCase

  # NOTE: LockController is not currently mapped to any route in router.ex
  # — Terraform lock/unlock requests are handled by TfController instead.
  # Remove the file (and the controller module) if the legacy controller
  # stays unused.

  describe "module is loadable" do
    test "module exists and exports the action functions" do
      functions = LynxWeb.LockController.__info__(:functions)
      assert Keyword.has_key?(functions, :lock)
      assert Keyword.has_key?(functions, :unlock)
    end
  end
end

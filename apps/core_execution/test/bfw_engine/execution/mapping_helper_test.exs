defmodule BfwEngine.Execution.MappingHelperTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Execution.MappingHelper

  describe "merge_over_input/2" do
    test "merges the published body over a map input token" do
      assert MappingHelper.merge_over_input(%{"a" => 1, "b" => 2}, %{"b" => 3}) ==
               %{"a" => 1, "b" => 3}
    end

    test "a scalar input token is replaced by the published body" do
      assert MappingHelper.merge_over_input(42, %{"value" => 42}) == %{"value" => 42}
    end

    test "a scalar published body replaces the input token" do
      assert MappingHelper.merge_over_input(%{"a" => 1}, "done") == "done"
    end
  end
end

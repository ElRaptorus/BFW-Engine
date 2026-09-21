defmodule BfwEngine.Types.IdentityTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Types.Identity

  describe "struct construction" do
    test "builds with required :id field" do
      identity = %Identity{id: "user-42"}

      assert identity.id == "user-42"
      assert identity.roles == []
      assert identity.groups == []
      assert identity.claims == %{}
    end

    test "builds with all fields" do
      identity = %Identity{
        id: "user-42",
        roles: ["admin", "operator"],
        groups: ["engineering"],
        claims: %{"deploy_bpmn" => true}
      }

      assert identity.id == "user-42"
      assert identity.roles == ["admin", "operator"]
      assert identity.groups == ["engineering"]
      assert identity.claims["deploy_bpmn"] == true
    end

    test "raises when :id is missing" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Identity, %{roles: ["admin"]})
      end
    end
  end
end

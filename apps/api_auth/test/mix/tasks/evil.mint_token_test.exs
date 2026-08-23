defmodule Mix.Tasks.Evil.MintTokenTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Evil.MintToken

  describe "full_privilege_claims/0" do
    test "includes lane:default as write and omits observe_all" do
      claims = MintToken.full_privilege_claims()

      assert claims["lane:default"] == "write"
      assert claims["zeeky_boogie_doog"] == true
      refute Map.has_key?(claims, "observe_all")
    end
  end

  describe "coerce_claim_value/1" do
    test "coerces boolean strings and leaves lane values as strings" do
      assert MintToken.coerce_claim_value("true") == true
      assert MintToken.coerce_claim_value("false") == false
      assert MintToken.coerce_claim_value("write") == "write"
      assert MintToken.coerce_claim_value("read") == "read"
    end
  end
end

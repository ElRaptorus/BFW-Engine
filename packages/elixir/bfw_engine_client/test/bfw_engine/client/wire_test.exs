defmodule BfwEngine.Client.WireTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Client.Wire

  describe "put_if_present/3" do
    test "omits the key when the value is nil" do
      assert Wire.put_if_present(%{}, "startEventId", nil) == %{}
    end

    test "puts the key when the value is present" do
      assert Wire.put_if_present(%{}, "startEventId", "Start_1") == %{"startEventId" => "Start_1"}
    end

    test "puts falsy-but-non-nil values" do
      assert Wire.put_if_present(%{}, "payload", %{}) == %{"payload" => %{}}
      assert Wire.put_if_present(%{}, "flag", false) == %{"flag" => false}
    end
  end

  describe "decode_type_properties/1" do
    test "returns nil unchanged" do
      assert Wire.decode_type_properties(nil) == nil
    end

    test "returns an already-decoded map unchanged" do
      assert Wire.decode_type_properties(%{
               "form_fields" => [
                 %{
                   "id" => "approved",
                   "type" => "toggle",
                   "label" => "Approved",
                   "required" => false
                 }
               ]
             }) == %{
               "form_fields" => [
                 %{
                   "id" => "approved",
                   "type" => "toggle",
                   "label" => "Approved",
                   "required" => false
                 }
               ]
             }
    end

    test "decodes a JSON-encoded string (AshGraphql's :map scalar encoding)" do
      assert Wire.decode_type_properties(~s({"message_name":"order-paid"})) == %{
               "message_name" => "order-paid"
             }
    end

    test "returns a non-JSON string unchanged instead of raising" do
      assert Wire.decode_type_properties("not json") == "not json"
    end
  end

  describe "normalize_flow_node_instance/1" do
    test "decodes a string-encoded typeProperties key" do
      result = %{"id" => "fni-1", "typeProperties" => ~s({"timer_ref":"ref-1"})}

      assert Wire.normalize_flow_node_instance(result) == %{
               "id" => "fni-1",
               "typeProperties" => %{"timer_ref" => "ref-1"}
             }
    end

    test "leaves the map unchanged when typeProperties is absent" do
      assert Wire.normalize_flow_node_instance(%{"id" => "fni-1"}) == %{"id" => "fni-1"}
    end
  end
end

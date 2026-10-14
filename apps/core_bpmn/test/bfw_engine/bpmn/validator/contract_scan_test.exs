defmodule BfwEngine.BPMN.Validator.ContractScanTest do
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN.Model.Definitions
  alias BfwEngine.BPMN.Validator
  alias BfwEngine.BPMN.Validator.ContractScan

  defp wrap(extension_xml, tag \\ "bpmn:serviceTask", id \\ "Task_1") do
    """
    <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
        xmlns:bfw="https://bifrostforge.world/schema/bpmn" id="D1">
      <bpmn:process id="P1">
        <#{tag} id="#{id}">
          <bpmn:extensionElements>#{extension_xml}</bpmn:extensionElements>
        </#{tag}>
      </bpmn:process>
    </bpmn:definitions>
    """
  end

  describe "offenders/1" do
    test "accepts JSON object contracts and blank contracts" do
      xml =
        wrap("""
        <bfw:payloadContract>{"type":"object"}</bfw:payloadContract>
        <bfw:resultContract>  </bfw:resultContract>
        """)

      assert ContractScan.offenders(xml) == []
    end

    test "accepts a contract in a CDATA section and with entities" do
      xml =
        wrap("""
        <bfw:payloadContract><![CDATA[{"type":"object","description":"a < b"}]]></bfw:payloadContract>
        <bfw:resultContract>{&quot;type&quot;:&quot;object&quot;}</bfw:resultContract>
        """)

      assert ContractScan.offenders(xml) == []
    end

    for {label, text} <- [
          {"malformed JSON", "{not json"},
          {"an array", "[1]"},
          {"a string", ~s("x")},
          {"a number", "5"},
          {"a boolean", "true"},
          {"null", "null"}
        ] do
      test "reports #{label} for each of the three contract elements" do
        for name <- ["payloadContract", "resultContract", "valueContract"] do
          xml =
            wrap("<bfw:#{name}>#{unquote(text) |> String.replace("&", "&amp;")}</bfw:#{name}>")

          assert ContractScan.offenders(xml) == [{name, "Task_1"}]
        end
      end
    end

    test "names the data object as owner of a value contract" do
      xml =
        wrap(~s(<bfw:valueContract>[]</bfw:valueContract>), "bpmn:dataObject", "DO_1")

      assert ContractScan.offenders(xml) == [{"valueContract", "DO_1"}]
    end

    test "finds offenders in a nested subprocess in document order" do
      xml = """
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
          xmlns:bfw="https://bifrostforge.world/schema/bpmn" id="D1">
        <bpmn:process id="P1">
          <bpmn:subProcess id="Sub_1">
            <bpmn:userTask id="Inner_1">
              <bpmn:extensionElements><bfw:resultContract>[]</bfw:resultContract></bpmn:extensionElements>
            </bpmn:userTask>
          </bpmn:subProcess>
          <bpmn:scriptTask id="Outer_1">
            <bpmn:extensionElements><bfw:payloadContract>oops</bfw:payloadContract></bpmn:extensionElements>
          </bpmn:scriptTask>
        </bpmn:process>
      </bpmn:definitions>
      """

      assert ContractScan.offenders(xml) == [
               {"resultContract", "Inner_1"},
               {"payloadContract", "Outer_1"}
             ]
    end

    test "returns no offenders for XML that cannot be parsed" do
      assert ContractScan.offenders("<not-closed") == []
      assert ContractScan.offenders("") == []
    end
  end

  describe "Validator.validate/1" do
    test "reports contract_not_json_object with the element and contract name" do
      definitions = %Definitions{
        definitions_id: "D1",
        raw_xml: wrap("<bfw:resultContract>[1]</bfw:resultContract>"),
        processes: []
      }

      assert {:error, [{:contract_not_json_object, message}]} = Validator.validate(definitions)

      assert message ==
               "Element 'Task_1' has a bfw:resultContract that is not a JSON object " <>
                 "(JSON Schema contracts must be objects)"
    end
  end
end

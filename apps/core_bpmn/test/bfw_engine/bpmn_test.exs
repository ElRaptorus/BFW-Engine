defmodule BfwEngine.BPMNTest do
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN

  test "supervision tree started" do
    assert Process.whereis(BfwEngine.BPMN.Supervisor)
  end

  describe "parse/1 delegate" do
    test "delegates to Parser" do
      xml = File.read!(Path.join([__DIR__, "..", "fixtures", "bpmns", "minimal_valid.bpmn"]))
      assert {:ok, %BfwEngine.BPMN.Model.Definitions{}} = BPMN.parse(xml)
    end
  end

  describe "validate/1 delegate" do
    test "delegates to Validator" do
      xml = File.read!(Path.join([__DIR__, "..", "fixtures", "bpmns", "minimal_valid.bpmn"]))
      {:ok, definitions} = BPMN.parse(xml)
      assert {:ok, ^definitions} = BPMN.validate(definitions)
    end
  end

  describe "parse_and_validate/1" do
    test "returns ok for a valid minimal BPMN" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:bfw="https://bifrostforge.world/schema/bpmn">
        <bpmn:process id="proc_1" isExecutable="true">
          <bpmn:extensionElements><bfw:version>1.0</bfw:version></bpmn:extensionElements>
          <bpmn:startEvent id="start_1"/>
          <bpmn:endEvent id="end_1"/>
          <bpmn:sequenceFlow id="sf_1" sourceRef="start_1" targetRef="end_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      assert {:ok, definitions} = BPMN.parse_and_validate(xml)
      assert length(definitions.processes) == 1
    end

    test "returns error when validation fails" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:bfw="https://bifrostforge.world/schema/bpmn">
        <bpmn:process id="proc_no_version" isExecutable="true">
          <bpmn:startEvent id="start_1"/>
          <bpmn:endEvent id="end_1"/>
          <bpmn:sequenceFlow id="sf_1" sourceRef="start_1" targetRef="end_1"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      assert {:error, violations} = BPMN.parse_and_validate(xml)
      assert is_list(violations)
      assert [_ | _] = violations
    end

    test "returns error when parsing fails" do
      assert {:error, reason} = BPMN.parse_and_validate("not xml at all <><>")
      assert reason != nil
    end
  end
end

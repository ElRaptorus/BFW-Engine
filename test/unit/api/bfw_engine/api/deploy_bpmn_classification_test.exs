defmodule BfwEngine.Api.DeployBpmnClassificationTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Api.Processes

  @fixtures_directory Path.expand("../../../../../test/fixtures/bpmns", __DIR__)
  @core_fixtures_directory Path.expand("../../../bpmn/fixtures/bpmns", __DIR__)
  @deployer %{id: "deployer"}

  defp deploy_fixture(filename) do
    xml = File.read!(Path.join(@fixtures_directory, filename))
    Processes.deploy_bpmn([%{filename: filename, xml: xml}], @deployer, skip_claims: true)
  end

  describe "deploy_bpmn/3 failure classification" do
    test "classifies a duplicate flow node id as a validation failure" do
      assert {:error, :validation_failed,
              [%{file: "invalid_duplicate_flow_node_id.bpmn", details: details}]} =
               deploy_fixture("invalid_duplicate_flow_node_id.bpmn")

      assert details == [
               "Flow node id 'End_1' is declared 2 times across the process and its subprocess scopes. Flow node ids must be unique within a process tree so that start-event resolution and subprocess scoping remain unambiguous."
             ]
    end

    test "classifies a dangling sequence flow sourceRef as a validation failure" do
      assert {:error, :validation_failed,
              [%{file: "invalid_dangling_sequence_flow_source.bpmn", details: details}]} =
               deploy_fixture("invalid_dangling_sequence_flow_source.bpmn")

      assert details == [
               "SequenceFlow 'Flow_dangling' references unknown source node 'Task_does_not_exist'"
             ]
    end

    test "classifies malformed XML as a parse error" do
      assert {:error, :parse_error, [%{file: "broken.bpmn", details: [_ | _]}]} =
               Processes.deploy_bpmn(
                 [%{filename: "broken.bpmn", xml: "<bpmn:definitions><unclosed>"}],
                 @deployer,
                 skip_claims: true
               )
    end

    test "classifies a DOCTYPE declaration as a parse error" do
      xml = ~s(<!DOCTYPE a [<!ENTITY b "c">]><bpmn:definitions/>)

      assert {:error, :parse_error,
              [
                %{
                  file: "doctype.bpmn",
                  details: ["DOCTYPE declarations are not allowed in BPMN files."]
                }
              ]} =
               Processes.deploy_bpmn([%{filename: "doctype.bpmn", xml: xml}], @deployer,
                 skip_claims: true
               )
    end

    test "reports a parse error when a batch mixes parser and validator failures" do
      valid_but_invalid =
        File.read!(Path.join(@fixtures_directory, "invalid_duplicate_flow_node_id.bpmn"))

      assert {:error, :parse_error, failures} =
               Processes.deploy_bpmn(
                 [
                   %{filename: "invalid.bpmn", xml: valid_but_invalid},
                   %{filename: "broken.bpmn", xml: "<unclosed"}
                 ],
                 @deployer,
                 skip_claims: true
               )

      assert Enum.map(failures, & &1.file) == ["invalid.bpmn", "broken.bpmn"]
    end

    test "rejects a non-executable process without bfw:version as a validation failure" do
      helper_with_version = """
        <bpmn:process id="Process_Helper" name="Helper" isExecutable="false">
          <bpmn:extensionElements>
            <bfw:version>1.0.0</bfw:version>
          </bpmn:extensionElements>
      """

      helper_without_version = """
        <bpmn:process id="Process_Helper" name="Helper" isExecutable="false">
      """

      xml =
        @core_fixtures_directory
        |> Path.join("multi_process.bpmn")
        |> File.read!()

      versionless = String.replace(xml, helper_with_version, helper_without_version)
      refute versionless == xml

      assert {:error, :validation_failed, [%{file: "multi_process.bpmn", details: details}]} =
               Processes.deploy_bpmn(
                 [%{filename: "multi_process.bpmn", xml: versionless}],
                 @deployer,
                 skip_claims: true
               )

      assert details == [
               "Process 'Process_Helper' is missing required property: version (bfw:version)"
             ]
    end
  end
end

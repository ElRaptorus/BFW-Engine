defmodule EvilEngine.Integration.Deployment.ChildLaneSetDeployTest do
  @moduledoc """
  Integration test for BPMN deploy with nested `childLaneSet` elements.

  Verifies that the REST deploy pipeline accepts BPMN containing nested lane
  sets and that the parser flattens child lanes into the parent lane set.
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.BPMN.ModelCache

  @process_model_id "ChildLaneSetProcess"

  describe "POST /processes — childLaneSet flattening" do
    test "deploys BPMN with nested childLaneSet and flattens lanes into ModelCache" do
      {201, deploy_body} = http_deploy("child_lane_set.bpmn")

      deployed = hd(deploy_body["deployed"])
      assert deployed["processModelId"] == @process_model_id
      assert deployed["version"] == "1.0.0"

      {200, versions} = http_list_versions(@process_model_id)
      version_id = List.first(versions)["versionId"]
      assert is_binary(version_id)

      assert {:ok, definitions} = ModelCache.fetch(version_id)
      [process] = definitions.processes

      lane_ids = Enum.map(process.lanes, & &1.id) |> Enum.sort()
      assert lane_ids == ["Lane_Child", "Lane_Parent"]

      parent_lane = Enum.find(process.lanes, &(&1.id == "Lane_Parent"))
      child_lane = Enum.find(process.lanes, &(&1.id == "Lane_Child"))

      assert parent_lane.flow_node_refs == ["Start_1"]
      assert child_lane.flow_node_refs == ["End_1"]
    end
  end
end

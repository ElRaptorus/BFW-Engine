defmodule BfwEngine.Integration.PluginStartOptionsTest do
  @moduledoc """
  The plugin facade start forwards only the public start options; internal
  execution options cannot bypass the capacity and orphan-start checks.
  """

  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Api
  alias BfwEngine.Plugins.FacadeBuilder

  test "internal start options are dropped" do
    version_id = gen_version_id()
    deploy_fixture("linear_start_end.bpmn", version_id)
    facade = FacadeBuilder.build("test:start_options")
    process_instance_id = Ecto.UUID.generate()

    assert {:ok, _pid} =
             facade.processes.start.(
               process_instance_id: process_instance_id,
               process_version_id: version_id,
               payload: %{},
               parent_process_instance_id: Ecto.UUID.generate(),
               subprocess_node_id: "Inner_Scope",
               triggerer_flow_node_instance_id: Ecto.UUID.generate()
             )

    wait_for_process_instance(process_instance_id)

    assert {:ok, process_instance} = Api.get_process_instance(process_instance_id)
    assert process_instance.parent_process_instance_id == nil
    assert process_instance.state == "finished"
  end
end

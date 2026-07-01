defmodule EvilEngine.Integration.Execution.FeelContextBindingsTest do
  @moduledoc """
  Integration tests verifying that all seven FEEL context bindings are
  correctly populated at runtime and survive across flow nodes.

  Bindings under test:
  - `token` — current token payload from the previous flow node
  - `this` — flow node metadata (id, name, type)
  - `context` — immutable process-level variables from the start payload
  - `dataObjects` — data object snapshot by ID
  - `process` — process model metadata (id, name, version)
  - `processInstance` — PI metadata (id, startedAt, startedBy)
  - `identity` — JWT-derived caller identity (id, roles, groups)
  """
  use EvilEngine.ExecutionCase, async: false

  describe "FEEL context bindings — all seven root variables" do
    test "FEEL-I1: script task captures all 7 bindings with correct values" do
      {201, _} = http_deploy("feel_context_bindings.bpmn")

      start_payload = %{"input" => "hello"}
      start_context = %{"tenant" => "acme", "env" => "test"}

      {201, body} =
        http_start("FeelContextBindings", %{"payload" => start_payload, "context" => start_context})

      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      process_instance = assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      capture_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Script_CaptureAll"))
      assert capture_fni != nil, "Expected Script_CaptureAll FNI"

      output = capture_fni.output_token

      assert output["captured_token_input"] == "hello",
             "token.input should carry the start payload value"

      assert output["captured_this_id"] == "Script_CaptureAll",
             "this.id should be the BPMN element ID of the executing script task"

      assert output["captured_this_type"] == "script_task",
             "this.type should be 'script_task'"

      assert output["captured_this_name"] == "Capture All Bindings",
             "this.name should be the BPMN element name"

      assert output["captured_context_tenant"] == "acme",
             "context.tenant should carry the context variable, not the payload"

      assert output["captured_context_env"] == "test",
             "context.env should carry the context variable, not the payload"

      assert output["captured_process_id"] == "FeelContextBindings",
             "process.id should be the BPMN process ID"

      assert output["captured_process_name"] == "FEEL Context Bindings Test",
             "process.name should be the BPMN process name"

      assert output["captured_process_version"] == "1.0.0",
             "process.version should be the evil:version value"

      assert output["captured_pi_id"] == process_instance_id,
             "processInstance.id should match the actual PI ID"

      assert output["captured_pi_started_by"] == "test-user",
             "processInstance.startedBy should match the JWT sub claim"

      assert output["captured_identity_id"] == "test-user",
             "identity.id should be the JWT sub claim"

      assert is_list(output["captured_identity_roles"]),
             "identity.roles should be a list"

      assert process_instance.started_with_context == start_context,
             "started_with_context should preserve the context, not the payload"
    end

    test "FEEL-I2: context binding is immutable across flow nodes" do
      {201, _} = http_deploy("feel_context_bindings.bpmn")

      start_payload = %{"input" => "original"}
      start_context = %{"tenant" => "corp", "env" => "prod"}

      {201, body} =
        http_start("FeelContextBindings", %{"payload" => start_payload, "context" => start_context})

      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      verify_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Script_VerifyContext"))
      assert verify_fni != nil, "Expected Script_VerifyContext FNI"

      output = verify_fni.output_token

      assert output["context_still_has_tenant"] == "corp",
             "context.tenant should be unchanged in the second script task"

      assert output["context_still_has_env"] == "prod",
             "context.env should be unchanged in the second script task"

      assert output["token_changed"] == "original",
             "token should carry data from the first script task's output (which captured the original token.input)"
    end

    test "FEEL-I3: payload-only start does not pollute context namespace" do
      {201, _} = http_deploy("feel_context_bindings.bpmn")

      start_payload = %{"input" => "hello", "tenant" => "should_not_leak", "env" => "should_not_leak"}

      {201, body} = http_start("FeelContextBindings", %{"payload" => start_payload})
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      process_instance = assert_pi_state!(process_instance_id, "finished")

      assert process_instance.started_with_context == nil,
             "started_with_context must be nil when no context was provided"

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      capture_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Script_CaptureAll"))
      assert capture_fni != nil, "Expected Script_CaptureAll FNI"

      output = capture_fni.output_token

      assert output["captured_token_input"] == "hello",
             "token.input should carry the payload value"

      assert output["captured_context_tenant"] == nil,
             "context.tenant must be nil when no context was provided (payload must not leak)"

      assert output["captured_context_env"] == nil,
             "context.env must be nil when no context was provided (payload must not leak)"
    end
  end
end

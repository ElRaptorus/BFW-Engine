defmodule BfwEngine.Test.ConformanceSteps do
  @moduledoc """
  Executes the declarative `steps:` list of a conformance spec.

  Every step is a one-key map: the key names the action, the value carries its
  arguments. Steps run in order after the spec's fixture is deployed and its
  process instance (alias `main`) is started. The vocabulary is documented in
  `docs/architecture/testing.md` (§`steps:` vocabulary); another engine runs the
  same YAML by implementing the same actions against the wire contract.

  Process instances and flow node instances are referred to by alias. `main` is
  the process instance started from the spec's `fixture`; `as:` stores a new
  alias; a flow node instance step without `fni:` uses the most recently
  awaited one.
  """

  import ExUnit.Assertions

  alias BfwEngine.ExecutionCase
  alias BfwEngine.Persistence.Api, as: Domain
  alias BfwEngine.Persistence.Resources.ProcessInstance, as: ProcessInstanceResource
  alias BfwEngine.Plugins.FacadeBuilder
  alias BfwEngine.Test.DbAssertions
  alias BfwEngine.Test.ExamplePlugin
  alias BfwEngine.Test.ProcessInteractions

  require Ash.Query

  @fixtures_directory Path.expand("../fixtures/bpmns", __DIR__)
  @default_timeout 10_000

  @doc "Registers the conformance example plugin (echo and async-park service task handlers)."
  def load_example_plugin do
    Application.put_env(
      :core_execution,
      :service_task_dispatch,
      BfwEngine.Plugins.RegistryDispatch
    )

    ExamplePlugin.on_load(FacadeBuilder.build("evil:conformance_plugin"))
  end

  @doc """
  Runs `steps` and returns the final state map. `main_process_instance_id` may
  be `nil` for specs that start their instances from a step.
  """
  def run(steps, main_process_instance_id) do
    initial_state = %{
      instances:
        if(main_process_instance_id, do: %{"main" => main_process_instance_id}, else: %{}),
      flow_node_instances: %{},
      process_versions: %{},
      last_flow_node_instance: nil
    }

    Enum.reduce(steps, initial_state, fn step, state ->
      [{action, arguments}] = Map.to_list(step)
      run_step(action, arguments || %{}, state)
    end)
  end

  # --- waiting and completing -------------------------------------------------

  defp run_step("await_waiting", arguments, state) do
    process_instance_id = instance_id(state, arguments)
    options = [timeout: timeout(arguments)]

    result =
      case arguments do
        %{"node_id" => node_id} ->
          ProcessInteractions.await_waiting_fni_by_node_id(process_instance_id, node_id, options)

        %{"type" => type} ->
          ProcessInteractions.await_waiting_flow_node_instance(process_instance_id, type, options)
      end

    remember_flow_node_instance(
      state,
      arguments["as"],
      unwrap!(result, "await_waiting #{inspect(arguments)}")
    )
  end

  defp run_step("finish_user_task", arguments, state) do
    process_instance_id = instance_id(state, arguments)
    values = arguments["values"] || %{}

    outcome =
      cond do
        arguments["node_id"] ->
          ProcessInteractions.finish_waiting_user_task_by_node_id(
            process_instance_id,
            arguments["node_id"],
            result: values,
            timeout: timeout(arguments)
          )

        arguments["any_waiting"] ->
          ProcessInteractions.finish_waiting_user_task(process_instance_id,
            result: values,
            timeout: timeout(arguments)
          )

        true ->
          ProcessInteractions.finish_user_task(
            process_instance_id,
            flow_node_instance_id(state, arguments),
            values
          )
      end

    assert_outcome!(outcome, arguments["expect_error"])
    state
  end

  defp run_step("cancel_user_task", arguments, state) do
    outcome =
      ProcessInteractions.cancel_user_task(
        instance_id(state, arguments),
        flow_node_instance_id(state, arguments),
        arguments["reason"]
      )

    assert_outcome!(outcome, nil)
    state
  end

  defp run_step("finish_manual_task", arguments, state) do
    outcome =
      ProcessInteractions.finish_manual_task(
        instance_id(state, arguments),
        flow_node_instance_id(state, arguments)
      )

    assert_outcome!(outcome, nil)
    state
  end

  defp run_step("finish_async_service_task", arguments, state) do
    outcome =
      ProcessInteractions.finish_async_service_task(
        flow_node_instance_id(state, arguments),
        arguments["result"]
      )

    assert_outcome!(outcome, nil)
    state
  end

  defp run_step("fail_async_service_task", arguments, state) do
    outcome =
      ProcessInteractions.fail_async_service_task(
        flow_node_instance_id(state, arguments),
        arguments["code"],
        arguments["message"]
      )

    assert_outcome!(outcome, nil)
    state
  end

  defp run_step("finish_transaction_cancel_gate", arguments, state) do
    wait =
      case arguments["on"] do
        "nested_child" -> {:on_nested_child, arguments["node_id"]}
        "transaction_child" -> {:on_transaction_child, arguments["node_id"]}
      end

    unwrap!(
      ProcessInteractions.finish_transaction_cancel_gate_after_nested_idle(
        instance_id(state, arguments),
        wait
      ),
      "finish_transaction_cancel_gate #{inspect(arguments)}"
    )

    state
  end

  # --- triggers ---------------------------------------------------------------

  defp run_step("trigger_message", arguments, state) do
    {200, result} =
      ExecutionCase.http_trigger_message(arguments["name"], arguments["payload"] || %{})

    check_trigger_result(result, arguments, state)
  end

  defp run_step("trigger_signal", %{"raw_body" => raw_body} = arguments, state) do
    path = "/signals/#{URI.encode_www_form(arguments["name"])}/trigger"

    conn =
      :post
      |> Plug.Test.conn(path, Jason.encode!(raw_body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header(
        "authorization",
        "Bearer #{ExecutionCase.sign_jwt(%{"trigger_signal" => "all"})}"
      )
      |> ExecutionCase.route()

    {200, result} = ExecutionCase.decode_response(conn)
    check_signal_result(result, arguments, state)
  end

  defp run_step("trigger_signal", arguments, state) do
    {200, result} = ExecutionCase.http_trigger_signal(arguments["name"])
    check_signal_result(result, arguments, state)
  end

  defp run_step("trigger_escalation", arguments, state) do
    {200, result} = ExecutionCase.http_trigger_escalation(arguments["code"])
    check_trigger_result(result, arguments, state)
  end

  defp run_step("trigger_timer", arguments, state) do
    {200, %{"triggered" => true}} =
      ExecutionCase.http_trigger_timer_event(flow_node_instance_id(state, arguments))

    state
  end

  # --- deployment and starting ------------------------------------------------

  defp run_step("deploy", fixtures, state) when is_list(fixtures) do
    Enum.each(fixtures, fn fixture -> {201, _body} = ExecutionCase.http_deploy(fixture) end)
    state
  end

  defp run_step("deploy_variant", arguments, state) do
    xml =
      @fixtures_directory
      |> Path.join(arguments["fixture"])
      |> File.read!()
      |> String.replace(
        ~r/<bfw:version>[^<]+<\/bfw:version>/,
        "<bfw:version>#{arguments["version"]}</bfw:version>"
      )
      |> replace_all(arguments["replace"] || %{})

    {201, _body} = ExecutionCase.http_deploy_xml(xml)
    state
  end

  defp run_step("start_process", arguments, state) do
    body = %{"payload" => arguments["payload"] || %{}}
    {status, response} = ExecutionCase.http_start(arguments["process_model_id"], body)

    assert status == (arguments["expect_status"] || 201),
           "start_process #{inspect(arguments)} answered #{status}"

    put_instance(state, arguments["as"], response["processInstanceId"])
  end

  defp run_step("await_other_instance", arguments, state) do
    excluded_ids = Enum.map(arguments["excluding"], &instance_id(state, %{"pi" => &1}))
    deadline = System.monotonic_time(:millisecond) + timeout(arguments)
    process_instance_id = poll_other_instance(excluded_ids, deadline)

    {:ok, _process_instance} =
      ProcessInteractions.await_process_instance_state(process_instance_id, arguments["state"],
        timeout: timeout(arguments)
      )

    put_instance(state, arguments["as"], process_instance_id)
  end

  # --- waiting for state ------------------------------------------------------

  defp run_step("await_state", arguments, state) do
    unwrap!(
      ProcessInteractions.await_process_instance_state(
        instance_id(state, arguments),
        arguments["state"],
        timeout: timeout(arguments)
      ),
      "await_state #{inspect(arguments)}"
    )

    state
  end

  defp run_step("await_completion", arguments, state) do
    ExecutionCase.wait_for_process_instance(instance_id(state, arguments), timeout(arguments))
    state
  end

  defp run_step("await_child", arguments, state) do
    unwrap!(
      ProcessInteractions.await_child_process_instance_state(instance_id(state, arguments),
        timeout: timeout(arguments)
      ),
      "await_child #{inspect(arguments)}"
    )

    state
  end

  defp run_step("await_finished_count", arguments, state) do
    unwrap!(
      ProcessInteractions.await_finished_fni_count_by_node_id(
        instance_id(state, arguments),
        arguments["node_id"],
        arguments["count"],
        timeout: timeout(arguments)
      ),
      "await_finished_count #{inspect(arguments)}"
    )

    state
  end

  defp run_step("pause", milliseconds, state) when is_integer(milliseconds) do
    Process.sleep(milliseconds)
    state
  end

  # --- process instance lifecycle ---------------------------------------------

  defp run_step("abort", arguments, state) do
    {204, nil} =
      ExecutionCase.http_abort_process_instance(
        instance_id(state, arguments),
        arguments["reason"] || "conformance_abort",
        %{"abort_process_instance" => "all"}
      )

    state
  end

  defp run_step("retry", arguments, state) do
    process_instance_id = instance_id(state, arguments)

    body =
      %{}
      |> put_present("version", arguments["version"])
      |> put_present(
        "resetToFlowNodeInstanceId",
        reset_checkpoint_id(process_instance_id, arguments["reset_to_node_id"])
      )

    case arguments["expect_error"] do
      nil ->
        {204, nil} = ExecutionCase.http_retry_process_instance(process_instance_id, body)

        {:ok, _pid} =
          ExecutionCase.poll_pi_alive(
            instance_id(state, %{"pi" => arguments["alive"] || arguments["pi"]}),
            5_000
          )

      expected_error ->
        {422, error_body} = ExecutionCase.http_retry_process_instance(process_instance_id, body)
        assert error_body["error"] == expected_error
        assert_conflicts_when_requested(error_body, arguments["expect_conflicts"])
    end

    state
  end

  defp run_step("restart_engine", _arguments, state) do
    {:ok, process_instance_pid} =
      BfwEngine.Execution.lookup_process_instance(instance_id(state, %{}))

    DynamicSupervisor.terminate_child(BfwEngine.Execution.Supervisor, process_instance_pid)
    Process.sleep(100)
    load_example_plugin()
    {:ok, _resumed} = BfwEngine.Execution.ResumeRunner.resume_all()
    Process.sleep(200)
    state
  end

  defp run_step("child", arguments, state) do
    parent_id = instance_id(state, %{"pi" => arguments["of"]})
    child_ids = DbAssertions.await_child_process_instance_ids(parent_id, timeout(arguments))

    child_id =
      case arguments["index"] do
        "first" -> hd(child_ids)
        "last" -> List.last(child_ids)
        nil -> only_child!(child_ids, parent_id)
      end

    put_instance(state, arguments["as"], child_id)
  end

  # --- assertions -------------------------------------------------------------

  defp run_step("assert_state", arguments, state) do
    DbAssertions.assert_pi_state!(instance_id(state, arguments), arguments["state"])
    state
  end

  defp run_step("assert_fni", arguments, state) do
    matching =
      state
      |> instance_id(arguments)
      |> DbAssertions.fetch_flow_node_instances()
      |> Enum.filter(&(&1.flow_node_id == arguments["node_id"]))

    assert_fni_count!(matching, arguments)
    assert_fni_state!(matching, arguments["state"], arguments["node_id"])
    state
  end

  defp run_step("assert_children", arguments, state) do
    child_ids = DbAssertions.list_child_process_instance_ids(instance_id(state, arguments))

    if arguments["includes"] do
      assert instance_id(state, %{"pi" => arguments["includes"]}) in child_ids
    end

    if arguments["excludes"] do
      refute instance_id(state, %{"pi" => arguments["excludes"]}) in child_ids
    end

    state
  end

  defp run_step("remember_process_version", arguments, state) do
    process_version_id =
      DbAssertions.fetch_process_instance!(instance_id(state, arguments)).process_version_id

    %{
      state
      | process_versions: Map.put(state.process_versions, arguments["as"], process_version_id)
    }
  end

  defp run_step("assert_process_version_changed", arguments, state) do
    current =
      DbAssertions.fetch_process_instance!(instance_id(state, arguments)).process_version_id

    assert current != Map.fetch!(state.process_versions, arguments["since"])
    state
  end

  defp run_step(action, _arguments, _state),
    do: flunk("unknown conformance step '#{action}'")

  # --- helpers ----------------------------------------------------------------

  defp instance_id(state, arguments) do
    alias_name = arguments["pi"] || "main"

    case Map.fetch(state.instances, alias_name) do
      {:ok, process_instance_id} -> process_instance_id
      :error -> flunk("conformance step refers to unknown process instance alias '#{alias_name}'")
    end
  end

  defp flow_node_instance_id(state, arguments) do
    case arguments["fni"] do
      nil -> state.last_flow_node_instance
      alias_name -> Map.fetch!(state.flow_node_instances, alias_name)
    end
  end

  defp remember_flow_node_instance(state, alias_name, flow_node_instance) do
    flow_node_instances =
      if alias_name,
        do: Map.put(state.flow_node_instances, alias_name, flow_node_instance.id),
        else: state.flow_node_instances

    %{
      state
      | flow_node_instances: flow_node_instances,
        last_flow_node_instance: flow_node_instance.id
    }
  end

  defp put_instance(state, nil, _process_instance_id), do: state

  defp put_instance(state, alias_name, process_instance_id),
    do: %{state | instances: Map.put(state.instances, alias_name, process_instance_id)}

  defp timeout(arguments), do: arguments["timeout"] || @default_timeout

  defp unwrap!({:ok, value}, _description), do: value
  defp unwrap!(other, description), do: flunk("#{description} failed: #{inspect(other)}")

  defp assert_outcome!(:ok, nil), do: :ok

  defp assert_outcome!({:error, {_status, body}}, expected_error) when is_binary(expected_error),
    do: assert(body["error"] == expected_error)

  defp assert_outcome!(outcome, expected_error),
    do: flunk("expected #{inspect(expected_error || :ok)}, got #{inspect(outcome)}")

  defp replace_all(xml, replacements),
    do:
      Enum.reduce(replacements, xml, fn {from, to}, current ->
        String.replace(current, from, to)
      end)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp reset_checkpoint_id(_process_instance_id, nil), do: nil

  defp reset_checkpoint_id(process_instance_id, node_id) do
    flow_node_instance =
      process_instance_id
      |> DbAssertions.fetch_flow_node_instances()
      |> Enum.find(&(&1.flow_node_id == node_id))

    assert flow_node_instance, "no flow node instance for checkpoint node '#{node_id}'"
    flow_node_instance.id
  end

  defp assert_conflicts_when_requested(_error_body, nil), do: :ok

  defp assert_conflicts_when_requested(error_body, true) do
    assert is_list(error_body["conflicts"])
    assert error_body["conflicts"] != []
  end

  defp only_child!([child_id], _parent_id), do: child_id

  defp only_child!(child_ids, parent_id),
    do: flunk("expected one child of #{parent_id}, got #{inspect(child_ids)}")

  defp assert_fni_count!(matching, %{"count" => count}), do: assert(length(matching) == count)

  defp assert_fni_count!(matching, %{"at_least" => minimum}),
    do: assert(length(matching) >= minimum)

  defp assert_fni_count!(matching, _arguments), do: assert(matching != [])

  defp assert_fni_state!(_matching, nil, _node_id), do: :ok

  defp assert_fni_state!(matching, expected_state, node_id),
    do:
      assert(
        Enum.any?(matching, &(&1.state == expected_state)),
        "no '#{node_id}' flow node instance in '#{expected_state}'"
      )

  defp check_signal_result(result, arguments, state) do
    assert is_binary(result["signalId"])
    assert result["signalName"] == arguments["name"]
    assert is_list(result["deliveries"])
    assert is_boolean(result["pending"])
    check_trigger_result(result, arguments, state)
  end

  defp check_trigger_result(result, arguments, state) do
    deliveries = result["deliveries"] || []
    started_ids = result["startedProcessInstanceIds"] || []

    if exact = arguments["expect_deliveries"], do: assert(length(deliveries) == exact)

    if minimum = arguments["expect_deliveries_at_least"],
      do: assert(length(deliveries) >= minimum)

    if minimum = arguments["expect_started_at_least"], do: assert(length(started_ids) >= minimum)

    if Map.has_key?(arguments, "expect_pending"),
      do: assert(result["pending"] == arguments["expect_pending"])

    if recipient = arguments["expect_delivery_to"] do
      assert hd(deliveries)["processInstanceId"] == instance_id(state, %{"pi" => recipient})
    end

    put_started_instance(state, arguments["as_started"], started_ids)
  end

  defp put_started_instance(state, nil, _started_ids), do: state

  defp put_started_instance(state, alias_name, [first_id | _rest]),
    do: put_instance(state, alias_name, first_id)

  defp poll_other_instance(excluded_ids, deadline) do
    candidate =
      ProcessInstanceResource
      |> Ash.Query.filter(id not in ^excluded_ids)
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(domain: Domain, authorize?: false)

    cond do
      candidate != [] ->
        hd(candidate).id

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("no further process instance was created")

      true ->
        Process.sleep(50)
        poll_other_instance(excluded_ids, deadline)
    end
  end
end

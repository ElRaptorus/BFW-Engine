defmodule EvilEngine.Execution.AdvancedEventsIntegrationTest do
  @moduledoc """
  Integration tests for BPMN event definitions that are parsed and validated
  but not yet fully implemented at runtime: compensation and cancel events.

  Unsupported-event scenarios verify that reaching the event causes the PI and
  the responsible FNI to transition to `:fatal` with diagnostic error metadata.
  Conditional and escalation events are now supported and are tested separately.
  """

  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Execution
  alias EvilEngine.Execution.TestSupport.BpmnFactory
  alias EvilEngine.Types.Event.FlowNodeInstanceFinished
  alias EvilEngine.Types.Identity

  @version_id "00000000-0000-0000-0000-advanced-ev-01"

  defmodule FatalEventCapturingSink do
    @moduledoc false
    @behaviour EvilEngine.Plugin.EventSink

    @impl true
    def init(opts) do
      {:ok, %{test_process: Keyword.fetch!(opts, :test_process)}}
    end

    @impl true
    def accepts?(%FlowNodeInstanceFinished{terminal_state: :fatal}), do: true
    def accepts?(_event), do: false

    @impl true
    def handle_event(%FlowNodeInstanceFinished{} = event, state) do
      send(state.test_process, {:fatal_flow_node_instance_finished, event})
      {:ok, state}
    end

    @impl true
    def handle_shutdown(_state), do: :ok
  end

  setup do
    Application.put_env(
      :core_execution,
      :persistence_adapter,
      EvilEngine.Execution.Persistence.NoOp
    )

    ModelCache.reset_state()
    EngineEventBus.reset_state()

    test_process = self()
    sink_name = "advanced-events-test-sink-#{System.unique_integer([:positive])}"

    :ok =
      EngineEventBus.register_sink(sink_name, FatalEventCapturingSink, test_process: test_process)

    on_exit(fn ->
      EngineEventBus.reset_state()
      Application.delete_env(:core_execution, :persistence_adapter)
      ModelCache.reset_state()
    end)

    %{sink_name: sink_name}
  end

  defp start_process_instance(version_id \\ @version_id, opts \\ []) do
    identity = %Identity{id: "test-user", roles: ["admin"], groups: []}

    process_instance_options = %{
      process_instance_id: opts[:process_instance_id] || random_id(),
      process_version_id: version_id,
      start_event_id: opts[:start_event_id],
      payload: opts[:payload] || %{},
      identity: identity
    }

    Execution.start_process_instance(process_instance_options)
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp attach_pi_telemetry(label) do
    test_process = self()
    reference = make_ref()

    :telemetry.attach(
      "pi-#{label}-#{inspect(reference)}",
      [:evil_engine, :process_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_process, {:pi_state_change, reference, metadata.new_state, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("pi-#{label}-#{inspect(reference)}") end)

    reference
  end

  defp attach_fni_telemetry(label) do
    test_process = self()
    reference = make_ref()

    :telemetry.attach(
      "fni-#{label}-#{inspect(reference)}",
      [:evil_engine, :flow_node_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_process, {:fni_state_change, reference, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("fni-#{label}-#{inspect(reference)}") end)

    reference
  end

  defp collect_fni_events(reference, timeout \\ 200) do
    collect_fni_events(reference, timeout, [])
  end

  defp collect_fni_events(reference, timeout, accumulated_events) do
    receive do
      {:fni_state_change, ^reference, metadata} ->
        if Map.has_key?(metadata, :terminal_state) do
          collect_fni_events(reference, timeout, [metadata | accumulated_events])
        else
          collect_fni_events(reference, timeout, accumulated_events)
        end
    after
      timeout -> Enum.reverse(accumulated_events)
    end
  end

  defp assert_unsupported_event_fatal(
         process_instance_reference,
         flow_node_instance_reference,
         expected_flow_node_id,
         expected_flow_node_type,
         expected_event_type
       ) do
    assert_receive {:pi_state_change, ^process_instance_reference, :fatal, process_metadata},
                   2_000

    assert process_metadata.process_instance_id

    fatal_flow_node_events =
      collect_fni_events(flow_node_instance_reference)
      |> Enum.filter(fn metadata -> metadata.terminal_state == :fatal end)

    assert Enum.any?(fatal_flow_node_events, fn metadata ->
             metadata.flow_node_type == expected_flow_node_type
           end)

    assert_receive {:fatal_flow_node_instance_finished,
                    %FlowNodeInstanceFinished{} = finished_event},
                   2_000

    assert finished_event.flow_node_id == expected_flow_node_id
    assert finished_event.flow_node_type == expected_flow_node_type
    assert finished_event.event_type == expected_event_type
    assert finished_event.terminal_state == :fatal
    assert finished_event.error_info["error_code"] == "unsupported_event_definition"
    assert finished_event.error_info["message"] =~ expected_flow_node_id
    assert finished_event.error_info["message"] =~ expected_event_type
  end

  describe "compensation throw event" do
    test "PI and FNI go fatal when compensation throw is reached" do
      definitions = BpmnFactory.compensation_throw_process()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("compensation-throw")
      flow_node_instance_reference = attach_fni_telemetry("compensation-throw-fni")

      assert {:ok, _process_instance_pid} = start_process_instance()

      assert_unsupported_event_fatal(
        process_instance_reference,
        flow_node_instance_reference,
        "Throw_Compensation",
        :intermediate_throw_event,
        "compensation"
      )
    end
  end

  describe "escalation throw event" do
    test "PI finishes normally and FNI is :finished when uncaught escalation throw is reached" do
      definitions = BpmnFactory.escalation_throw_process()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("escalation-throw")
      flow_node_instance_reference = attach_fni_telemetry("escalation-throw-fni")

      assert {:ok, _process_instance_pid} = start_process_instance()

      assert_receive {:pi_state_change, ^process_instance_reference, :finished, _process_metadata},
                     2_000

      all_fni_events = collect_fni_events(flow_node_instance_reference)

      assert Enum.any?(all_fni_events, fn metadata ->
               metadata.flow_node_type == :intermediate_throw_event and
                 metadata.terminal_state == :finished
             end),
             "Expected escalation throw FNI to finish as :finished"

      refute Enum.any?(all_fni_events, fn metadata ->
               metadata.terminal_state == :fatal
             end),
             "No FNI should be :fatal for a supported escalation throw"
    end
  end

  describe "cancel end event" do
    test "PI and FNI go fatal when cancel end event is reached" do
      definitions = BpmnFactory.cancel_end_event_process()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("cancel-end")
      flow_node_instance_reference = attach_fni_telemetry("cancel-end-fni")

      assert {:ok, _process_instance_pid} = start_process_instance()

      assert_unsupported_event_fatal(
        process_instance_reference,
        flow_node_instance_reference,
        "End_Cancel",
        :end_event,
        "cancel"
      )
    end
  end

  describe "conditional catch event" do
    test "conditional catch parks as waiting when condition is false" do
      definitions = BpmnFactory.conditional_catch_process()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("conditional-catch")
      _flow_node_instance_reference = attach_fni_telemetry("conditional-catch-fni")

      assert {:ok, _process_instance_pid} = start_process_instance()

      assert_receive {:pi_state_change, ^process_instance_reference, :running, _metadata}, 2_000

      refute_receive {:pi_state_change, ^process_instance_reference, :fatal, _metadata}, 500
    end
  end
end

defmodule BfwEngine.Execution.CompensationObservabilityTest do
  @moduledoc """
  Workstream 8 — Compensate Throw emits FlowNodeInstanceFinished,
  compensation ESP park emits StateChanged active→waiting, and a child
  PI that ends `:compensated` completes the parent Call Activity.
  """
  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.ModelCache
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Execution
  alias BfwEngine.Execution.CalledElementResolver
  alias BfwEngine.Execution.TestSupport.BpmnFactory
  alias BfwEngine.Types.Event
  alias BfwEngine.Types.Identity

  defmodule CompensationEventSink do
    @moduledoc false
    @behaviour BfwEngine.Plugin.EventSink

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def accepts?(%Event.FlowNodeInstanceFinished{}), do: true
    def accepts?(%Event.FlowNodeInstanceStateChanged{}), do: true
    def accepts?(_event), do: false

    @impl true
    def handle_event(%Event.FlowNodeInstanceFinished{} = event, state) do
      send(state.test_pid, {:fni_finished, event})
      {:ok, state}
    end

    def handle_event(%Event.FlowNodeInstanceStateChanged{} = event, state) do
      send(state.test_pid, {:fni_state_changed, event})
      {:ok, state}
    end

    @impl true
    def handle_shutdown(_state), do: :ok
  end

  setup do
    Application.put_env(
      :core_execution,
      :persistence_adapter,
      BfwEngine.Execution.Persistence.NoOp
    )

    Application.put_env(:core_execution, :called_element_resolver, CalledElementResolver.NoOp)
    ModelCache.reset_state()
    CalledElementResolver.NoOp.reset()

    sink_name = "test:compensation-obs-#{inspect(self())}"
    :ok = EngineEventBus.register_sink(sink_name, CompensationEventSink, test_pid: self())

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
      Application.delete_env(:core_execution, :called_element_resolver)
      ModelCache.reset_state()
      CalledElementResolver.NoOp.reset()
    end)

    :ok
  end

  test "Compensate Throw emits FlowNodeInstanceFinished and not StateChanged waiting→finished" do
    version_id = random_id()
    ModelCache.put_new(version_id, BpmnFactory.compensation_with_handler_process())

    process_instance_id = random_id()
    pi_ref = attach_pi_telemetry()

    assert {:ok, process_instance_pid} =
             start_process_instance(version_id, process_instance_id)

    assert_receive {:pi_state_change, ^pi_ref, :finished, _}, 2_000
    await_process_death(process_instance_pid)

    finished_events = collect_messages(:fni_finished)
    state_changed_events = collect_messages(:fni_state_changed)

    throw_finished =
      Enum.filter(finished_events, fn event ->
        event.flow_node_id == "Throw_Compensation"
      end)

    assert Enum.any?(throw_finished, fn event -> event.terminal_state == :finished end)

    refute Enum.any?(state_changed_events, fn event ->
             event.flow_node_id == "Throw_Compensation" and event.new_state == :finished
           end)
  end

  test "compensation ESP park emits StateChanged active→waiting on the throw FNI" do
    version_id = random_id()
    ModelCache.put_new(version_id, BpmnFactory.compensation_throw_with_esp_process())

    process_instance_id = random_id()
    pi_ref = attach_pi_telemetry()

    assert {:ok, process_instance_pid} =
             start_process_instance(version_id, process_instance_id)

    assert_receive {:pi_state_change, ^pi_ref, :finished, _}, 3_000
    await_process_death(process_instance_pid)

    state_changed_events = collect_messages(:fni_state_changed)

    assert Enum.any?(state_changed_events, fn event ->
             event.flow_node_id == "Throw_Compensation" and event.old_state == :active and
               event.new_state == :waiting
           end)
  end

  test "child PI ending compensated completes the parent Call Activity" do
    child_version = random_id()
    parent_version = random_id()

    ModelCache.put_new(child_version, BpmnFactory.compensate_end_process("child-process"))
    CalledElementResolver.NoOp.set_version("child-process", child_version)
    ModelCache.put_new(parent_version, BpmnFactory.call_activity_process())

    process_instance_id = random_id()
    pi_ref = attach_pi_telemetry()

    assert {:ok, process_instance_pid} =
             start_process_instance(parent_version, process_instance_id)

    assert_receive {:pi_state_change, ^pi_ref, :finished, _}, 3_000
    refute_receive {:pi_state_change, ^pi_ref, :fatal, _}, 50
    await_process_death(process_instance_pid)
  end

  defp start_process_instance(version_id, process_instance_id) do
    Execution.start_process_instance(%{
      process_instance_id: process_instance_id,
      process_version_id: version_id,
      payload: %{},
      identity: %Identity{id: "test-user", roles: ["admin"], groups: []}
    })
  end

  defp attach_pi_telemetry do
    test_process = self()
    reference = make_ref()

    :telemetry.attach(
      "pi-ws8-#{inspect(reference)}",
      [:bfw_engine, :process_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_process, {:pi_state_change, reference, metadata.new_state, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("pi-ws8-#{inspect(reference)}") end)

    reference
  end

  defp await_process_death(pid) do
    monitor_ref = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _}, 2_000
  end

  defp collect_messages(tag) do
    collect_messages(tag, [])
  end

  defp collect_messages(tag, acc) do
    receive do
      {^tag, event} -> collect_messages(tag, [event | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

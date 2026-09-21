defmodule BfwEngine.Execution.CallActivityRootIdTest do
  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.ModelCache
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Execution
  alias BfwEngine.Execution.CalledElementResolver
  alias BfwEngine.Execution.TestSupport.BpmnFactory
  alias BfwEngine.Types.Event
  alias BfwEngine.Types.Identity

  @parent_version "ca-root-parent-version"
  @child_version "ca-root-child-version"

  defmodule RootIdSink do
    @moduledoc false
    @behaviour BfwEngine.Plugin.EventSink

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def accepts?(%Event.FlowNodeInstanceStarted{}), do: true
    def accepts?(_event), do: false

    @impl true
    def handle_event(event, state) do
      send(state.test_pid, {:fni_started, event})
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

    sink_name = "test:ca-root-#{inspect(self())}"
    :ok = EngineEventBus.register_sink(sink_name, RootIdSink, test_pid: self())

    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "ca-root-child-#{inspect(ref)}",
      [:bfw_engine, :call_activity, :child_started],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:ca_child_started, ref, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("ca-root-child-#{inspect(ref)}")
      Application.delete_env(:core_execution, :persistence_adapter)
      Application.delete_env(:core_execution, :called_element_resolver)
      ModelCache.reset_state()
      CalledElementResolver.NoOp.reset()
    end)

    {:ok, ref: ref}
  end

  test "child process instance inherits the parent's root_process_instance_id", %{ref: ref} do
    child_definitions = BpmnFactory.user_task_process(process_id: "child-process")
    ModelCache.put_new(@child_version, child_definitions)
    CalledElementResolver.NoOp.set_version("child-process", @child_version)

    parent_definitions = BpmnFactory.call_activity_process()
    ModelCache.put_new(@parent_version, parent_definitions)

    parent_process_instance_id = random_id()

    assert {:ok, _process_instance_pid} =
             Execution.start_process_instance(%{
               process_instance_id: parent_process_instance_id,
               process_version_id: @parent_version,
               payload: %{},
               identity: %Identity{id: "test-user", roles: ["admin"], groups: []}
             })

    assert_receive(
      {:ca_child_started, ^ref,
       %{
         parent_process_instance_id: ^parent_process_instance_id,
         child_process_instance_id: child_id
       }},
      2_000
    )

    Process.sleep(50)
    {:ok, child_pid} = Execution.lookup_process_instance(child_id)
    {:running, child_state} = :sys.get_state(child_pid)

    assert child_state.root_process_instance_id == parent_process_instance_id
    refute child_state.root_process_instance_id == child_id

    assert_receive {:fni_started, %Event.FlowNodeInstanceStarted{} = started}, 2_000

    child_started =
      receive_until_child_fni_started(child_id, started)

    assert child_started.root_process_instance_id == parent_process_instance_id
    assert child_started.process_instance_id == child_id
  end

  defp receive_until_child_fni_started(child_id, %Event.FlowNodeInstanceStarted{} = event) do
    if event.process_instance_id == child_id do
      event
    else
      assert_receive {:fni_started, next_event}, 2_000
      receive_until_child_fni_started(child_id, next_event)
    end
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

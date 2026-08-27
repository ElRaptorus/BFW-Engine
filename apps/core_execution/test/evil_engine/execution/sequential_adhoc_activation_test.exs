defmodule EvilEngine.Execution.SequentialAdhocActivationTest do
  @moduledoc """
  Workstream 10 — sequential ad-hoc initial activation uses the first
  `activeElements` id in FEEL list order, not inner-activity model order.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Execution
  alias EvilEngine.Execution.CalledElementResolver
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Execution.TestSupport.BpmnFactory
  alias EvilEngine.Types.Event
  alias EvilEngine.Types.Identity

  defmodule ActivationSink do
    @moduledoc false
    @behaviour EvilEngine.Plugin.EventSink

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def accepts?(%Event.AdHocActivityActivated{}), do: true
    def accepts?(_event), do: false

    @impl true
    def handle_event(%Event.AdHocActivityActivated{} = event, state) do
      send(state.test_pid, {:adhoc_activated, event})
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

    Application.put_env(:core_execution, :called_element_resolver, CalledElementResolver.NoOp)
    ModelCache.reset_state()
    CalledElementResolver.NoOp.reset()

    sink_name = "test:seq-adhoc-#{inspect(self())}"
    :ok = EngineEventBus.register_sink(sink_name, ActivationSink, test_pid: self())

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
      Application.delete_env(:core_execution, :called_element_resolver)
      ModelCache.reset_state()
      CalledElementResolver.NoOp.reset()
    end)

    :ok
  end

  test "sequential ad-hoc activates only the first FEEL list id" do
    version_id = random_id()
    ModelCache.put_new(version_id, BpmnFactory.sequential_adhoc_user_tasks())
    process_instance_id = random_id()

    log =
      capture_log(fn ->
        assert {:ok, process_instance_pid} =
                 Execution.start_process_instance(%{
                   process_instance_id: process_instance_id,
                   process_version_id: version_id,
                   payload: %{},
                   identity: %Identity{id: "test-user", roles: ["admin"], groups: ["all"]}
                 })

        assert_receive {:adhoc_activated,
                        %Event.AdHocActivityActivated{activated_flow_node_id: "Task_C"}},
                       2_000

        refute_receive {:adhoc_activated, _}, 200

        ProcessInstance.abort(process_instance_pid, "test cleanup", %Identity{
          id: "test-user",
          roles: ["admin"],
          groups: ["all"]
        })
      end)

    assert log =~ "Task_C"
    assert log =~ "Task_A"
  end

  test "parallel ad-hoc activates every id in the FEEL list" do
    version_id = random_id()

    ModelCache.put_new(
      version_id,
      BpmnFactory.sequential_adhoc_user_tasks(adhoc_ordering: :parallel)
    )

    process_instance_id = random_id()

    assert {:ok, process_instance_pid} =
             Execution.start_process_instance(%{
               process_instance_id: process_instance_id,
               process_version_id: version_id,
               payload: %{},
               identity: %Identity{id: "test-user", roles: ["admin"], groups: ["all"]}
             })

    activated_ids =
      for _index <- 1..2 do
        assert_receive {:adhoc_activated,
                        %Event.AdHocActivityActivated{activated_flow_node_id: id}},
                       2_000

        id
      end

    assert Enum.sort(activated_ids) == ["Task_A", "Task_C"]
    refute_receive {:adhoc_activated, _}, 200

    ProcessInstance.abort(process_instance_pid, "test cleanup", %Identity{
      id: "test-user",
      roles: ["admin"],
      groups: ["all"]
    })
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

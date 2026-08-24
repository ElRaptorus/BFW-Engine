defmodule EvilEngine.Execution.ResumeTest do
  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Events.MessageSubscriptions
  alias EvilEngine.Execution
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Execution.ResumeRunner
  alias EvilEngine.Execution.TestSupport.BpmnFactory
  alias EvilEngine.Timers.Scheduler
  alias EvilEngine.Types.Event
  alias EvilEngine.Types.Identity

  @version_id "00000000-0000-0000-0000-000000000001"

  setup do
    Application.put_env(
      :core_execution,
      :persistence_adapter,
      EvilEngine.Execution.Persistence.NoOp
    )

    ModelCache.reset_state()

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
      ModelCache.reset_state()
    end)
  end

  defmodule ResumeOverloadSink do
    @moduledoc false
    @behaviour EvilEngine.Plugin.EventSink

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def accepts?(%Event.EngineOverloaded{}), do: true
    def accepts?(_event), do: false

    @impl true
    def handle_event(event, %{test_pid: test_pid} = state) do
      send(test_pid, {:resume_overload, event})
      {:ok, state}
    end

    @impl true
    def handle_shutdown(_state), do: :ok
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp resume_pi(process_instance_id, version_id, flow_node_instance_data, opts \\ []) do
    resume_opts = %{
      resume: true,
      process_instance_id: process_instance_id,
      process_version_id: version_id,
      business_key: opts[:business_key],
      parent_process_instance_id: nil,
      triggerer_flow_node_instance_id: nil,
      started_at: DateTime.utc_now(),
      started_by: %{"id" => "test-user", "roles" => ["admin"], "groups" => []},
      started_with_context: opts[:context] || %{"input" => "data"},
      fni_data: flow_node_instance_data
    }

    Execution.start_process_instance(resume_opts)
  end

  # -------------------------------------------------------------------
  # U1: Resume PI with active task (re-dispatch)
  # -------------------------------------------------------------------

  describe "U1: Resume PI with active task (re-dispatch)" do
    test "active FNI is re-dispatched through handler, PI completes" do
      definitions = BpmnFactory.linear_three_node()
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()
      flow_node_instance_id = random_id()

      flow_node_instance_data = [
        %{
          id: flow_node_instance_id,
          flow_node_id: "Task_1",
          flow_node_type: "task",
          state: "active",
          input_token: %{"input" => "data"},
          type_properties: %{},
          previous_flow_node_instance_ids: [],
          lane_name: nil,
          started_at: DateTime.utc_now()
        }
      ]

      assert {:ok, process_instance_pid} =
               resume_pi(process_instance_id, @version_id, flow_node_instance_data)

      ref = Process.monitor(process_instance_pid)
      assert_receive {:DOWN, ^ref, :process, ^process_instance_pid, _}, 2_000
    end
  end

  # -------------------------------------------------------------------
  # U2: Resume PI with waiting user task
  # -------------------------------------------------------------------

  describe "U2: Resume PI with waiting user task" do
    test "FNI stays in :waiting, finish call completes PI" do
      definitions = BpmnFactory.user_task_process()
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()
      flow_node_instance_id = random_id()

      flow_node_instance_data = [
        %{
          id: flow_node_instance_id,
          flow_node_id: "UserTask_1",
          flow_node_type: "user_task",
          state: "waiting",
          input_token: %{"input" => "data"},
          type_properties: %{},
          previous_flow_node_instance_ids: [],
          lane_name: nil,
          started_at: DateTime.utc_now()
        }
      ]

      assert {:ok, process_instance_pid} =
               resume_pi(process_instance_id, @version_id, flow_node_instance_data)

      Process.sleep(50)
      assert Process.alive?(process_instance_pid)

      {:running, state} = :sys.get_state(process_instance_pid)
      assert %{^flow_node_instance_id => %{state: :waiting}} = state.flow_node_instance_states

      identity = %Identity{id: "finisher"}

      assert :ok =
               ProcessInstance.finish_user_task(
                 process_instance_pid,
                 flow_node_instance_id,
                 %{"approved" => true},
                 identity
               )

      Process.sleep(100)
      refute Process.alive?(process_instance_pid)
    end
  end

  # -------------------------------------------------------------------
  # U3: Resume PI with waiting manual task
  # -------------------------------------------------------------------

  describe "U3: Resume PI with waiting manual task" do
    test "FNI stays in :waiting, finish call completes PI" do
      definitions = BpmnFactory.manual_task_process(true)
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()
      flow_node_instance_id = random_id()

      flow_node_instance_data = [
        %{
          id: flow_node_instance_id,
          flow_node_id: "ManualTask_1",
          flow_node_type: "manual_task",
          state: "waiting",
          input_token: %{"input" => "data"},
          type_properties: %{},
          previous_flow_node_instance_ids: [],
          lane_name: nil,
          started_at: DateTime.utc_now()
        }
      ]

      assert {:ok, process_instance_pid} =
               resume_pi(process_instance_id, @version_id, flow_node_instance_data)

      Process.sleep(50)
      assert Process.alive?(process_instance_pid)

      identity = %Identity{id: "user"}

      assert :ok =
               ProcessInstance.finish_user_task(
                 process_instance_pid,
                 flow_node_instance_id,
                 %{},
                 identity
               )

      Process.sleep(100)
      refute Process.alive?(process_instance_pid)
    end
  end

  # -------------------------------------------------------------------
  # U4: Resume PI with async service task
  # -------------------------------------------------------------------

  describe "U4: Resume PI with async service task" do
    test "Registry has {:fni, flow_node_instance_id} entry, plugin can complete" do
      definitions = BpmnFactory.service_task_process("echo")
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()
      flow_node_instance_id = random_id()

      flow_node_instance_data = [
        %{
          id: flow_node_instance_id,
          flow_node_id: "ServiceTask_1",
          flow_node_type: "service_task",
          state: "waiting",
          input_token: %{"input" => "data"},
          type_properties: %{"async" => true},
          previous_flow_node_instance_ids: [],
          lane_name: nil,
          started_at: DateTime.utc_now()
        }
      ]

      assert {:ok, process_instance_pid} =
               resume_pi(process_instance_id, @version_id, flow_node_instance_data)

      Process.sleep(50)
      assert Process.alive?(process_instance_pid)

      assert [{^process_instance_pid, :async}] =
               Registry.lookup(EvilEngine.Execution.Registry, {:fni, flow_node_instance_id})

      assert :ok =
               ProcessInstance.finish_async_service_task(
                 process_instance_pid,
                 flow_node_instance_id,
                 %{"result" => "done"}
               )

      Process.sleep(100)
      refute Process.alive?(process_instance_pid)
    end
  end

  # -------------------------------------------------------------------
  # U5: Resume emits ProcessInstanceStateChanged
  # -------------------------------------------------------------------

  describe "U5: Resume emits ProcessInstanceStateChanged" do
    test "ProcessInstanceStateChanged{old_state: nil, new_state: :running} is emitted" do
      definitions = BpmnFactory.user_task_process()
      ModelCache.put_new(@version_id, definitions)

      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "resume-test-#{inspect(ref)}",
        [:evil_engine, :process_instance, :state_change],
        fn _event, _measurements, metadata, _config ->
          if metadata.old_state == nil and metadata.new_state == :running do
            send(test_pid, {:state_changed, ref, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("resume-test-#{inspect(ref)}") end)

      process_instance_id = random_id()

      flow_node_instance_data = [
        %{
          id: random_id(),
          flow_node_id: "UserTask_1",
          flow_node_type: "user_task",
          state: "waiting",
          input_token: %{},
          type_properties: %{},
          previous_flow_node_instance_ids: [],
          lane_name: nil,
          started_at: DateTime.utc_now()
        }
      ]

      assert {:ok, _process_instance_pid} =
               resume_pi(process_instance_id, @version_id, flow_node_instance_data)

      assert_receive {:state_changed, ^ref, %{old_state: nil, new_state: :running}}, 500
    end
  end

  # -------------------------------------------------------------------
  # U7: Resume PI with multiple FNIs in different states
  # -------------------------------------------------------------------

  describe "U7: Resume PI with multiple FNIs in different states" do
    test "only waiting FNIs are reactivated, finished ones preserved" do
      definitions = BpmnFactory.user_task_process()
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()
      waiting_fni_id = random_id()
      finished_fni_id = random_id()

      flow_node_instance_data = [
        %{
          id: waiting_fni_id,
          flow_node_id: "UserTask_1",
          flow_node_type: "user_task",
          state: "waiting",
          input_token: %{"input" => "data"},
          type_properties: %{},
          previous_flow_node_instance_ids: [],
          lane_name: nil,
          started_at: DateTime.utc_now()
        },
        %{
          id: finished_fni_id,
          flow_node_id: "Start_1",
          flow_node_type: "start_event",
          state: "finished",
          input_token: %{"input" => "data"},
          type_properties: %{},
          previous_flow_node_instance_ids: [],
          lane_name: nil,
          started_at: DateTime.utc_now()
        }
      ]

      assert {:ok, process_instance_pid} =
               resume_pi(process_instance_id, @version_id, flow_node_instance_data)

      Process.sleep(50)
      assert Process.alive?(process_instance_pid)

      {:running, state} = :sys.get_state(process_instance_pid)
      assert state.flow_node_instance_states[waiting_fni_id].state == :waiting
      assert state.flow_node_instance_states[finished_fni_id].state == :finished
    end
  end

  # -------------------------------------------------------------------
  # U6: Resume with ModelCache miss (auto-heal from loader)
  # -------------------------------------------------------------------

  describe "U6: Resume with empty ModelCache auto-heals via loader" do
    @u6_version_id "00000000-0000-0000-0000-000000000006"

    @user_task_xml """
    <?xml version="1.0" encoding="UTF-8"?>
    <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                      xmlns:evil="https://evilengine.dev/schema/bpmn"
                      id="Definitions_1">
      <bpmn:process id="Process_1" name="AutoHeal" isExecutable="true">
        <bpmn:extensionElements>
          <evil:version>1.0.0</evil:version>
        </bpmn:extensionElements>
        <bpmn:startEvent id="Start_1">
          <bpmn:outgoing>Flow_1</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:userTask id="UserTask_1" name="Review">
          <bpmn:incoming>Flow_1</bpmn:incoming>
          <bpmn:outgoing>Flow_2</bpmn:outgoing>
        </bpmn:userTask>
        <bpmn:endEvent id="End_1">
          <bpmn:incoming>Flow_2</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="UserTask_1"/>
        <bpmn:sequenceFlow id="Flow_2" sourceRef="UserTask_1" targetRef="End_1"/>
      </bpmn:process>
    </bpmn:definitions>
    """

    test "resume succeeds when model is not in cache but loader provides XML" do
      Application.put_env(:core_bpmn, :model_cache_loader, {__MODULE__, :mock_load_xml})

      on_exit(fn ->
        Application.delete_env(:core_bpmn, :model_cache_loader)
      end)

      ModelCache.reset_state()

      process_instance_id = random_id()
      flow_node_instance_id = random_id()

      flow_node_instance_data = [
        %{
          id: flow_node_instance_id,
          flow_node_id: "UserTask_1",
          flow_node_type: "user_task",
          state: "waiting",
          input_token: %{"input" => "data"},
          type_properties: %{},
          previous_flow_node_instance_ids: [],
          lane_name: nil,
          started_at: DateTime.utc_now()
        }
      ]

      assert {:ok, process_instance_pid} =
               resume_pi(process_instance_id, @u6_version_id, flow_node_instance_data)

      Process.sleep(50)
      assert Process.alive?(process_instance_pid)

      {:running, state} = :sys.get_state(process_instance_pid)
      assert state.flow_node_instance_states[flow_node_instance_id].state == :waiting
      assert state.process_model != nil
    end
  end

  def mock_load_xml(@u6_version_id), do: {:ok, @user_task_xml}
  def mock_load_xml(_), do: {:error, :not_found}

  defmodule ConfigurableResumeAdapter do
    @moduledoc false
    @behaviour EvilEngine.Execution.Persistence

    defp fixture, do: Application.get_env(:core_execution, :resume_test_fixture, %{})

    @impl true
    def list_running_process_instances(_opts) do
      records = Map.get(fixture(), :records, [])
      {:ok, %{records: records, next_cursor: nil}}
    end

    @impl true
    def list_flow_node_instances(_process_instance_id) do
      Map.get(fixture(), :list_flow_node_instances, {:ok, []})
    end

    @impl true
    def create_process_instance(attributes), do: {:ok, attributes}
    @impl true
    def update_process_instance(_id, _changes), do: :ok
    @impl true
    def create_flow_node_instance(attributes), do: {:ok, attributes}
    @impl true
    def update_flow_node_instance(_id, _action, _changes), do: :ok
    @impl true
    def finish_fni_with_data_objects(_id, _changes, _intents), do: {:ok, %{writes: []}}
    @impl true
    def write_data_object(_params), do: {:ok, %{write_id: "mock", created_at: DateTime.utc_now()}}
    @impl true
    def list_data_objects(_id), do: {:ok, []}
    @impl true
    def cleanup_orphaned_flow_node_instances, do: {:ok, 0}
    @impl true
    def cleanup_orphaned_process_instances, do: {:ok, 0}
    @impl true
    def get_process_instance_for_retry(_id), do: {:error, :not_found}
    @impl true
    def list_all_flow_node_instances(_id), do: {:ok, []}
    @impl true
    def execute_retry_reset(_id, _opts), do: {:ok, []}
    @impl true
    def revert_retry(_id, _state, _finished_at), do: :ok
    @impl true
    def list_child_process_instances(_), do: {:ok, []}
    @impl true
    def patch_fni_type_properties(_, _), do: :ok
    @impl true
    def create_gateway_pending_arrival(_params), do: :ok
    @impl true
    def list_gateway_pending_arrivals(_process_instance_id), do: {:ok, []}
    @impl true
    def delete_gateway_pending_arrivals_for_gateway(_fni_id), do: :ok
  end

  # -------------------------------------------------------------------
  # ResumeRunner with NoOp adapter
  # -------------------------------------------------------------------

  describe "ResumeRunner with NoOp adapter" do
    test "resume_all returns {:ok, 0} when no running PIs" do
      assert {:ok, 0} = ResumeRunner.resume_all()
    end
  end

  # -------------------------------------------------------------------
  # Startup orphan cleanup — verify cleanup runs before resume
  # -------------------------------------------------------------------

  describe "ResumeRunner orphan cleanup" do
    test "cleanup_orphans is called with the adapter and succeeds with NoOp" do
      assert {:ok, 0} = ResumeRunner.resume_all()
    end

    test "cleanup_orphans tolerates adapter returning errors without crashing" do
      defmodule FailingCleanupAdapter do
        @moduledoc false
        @behaviour EvilEngine.Execution.Persistence

        @impl true
        def cleanup_orphaned_flow_node_instances, do: {:error, :db_connection_lost}

        @impl true
        def cleanup_orphaned_process_instances, do: {:error, :db_connection_lost}

        @impl true
        def list_running_process_instances(_opts),
          do: {:ok, %{records: [], next_cursor: nil}}

        @impl true
        def create_process_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_process_instance(_id, _changes), do: :ok
        @impl true
        def create_flow_node_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_flow_node_instance(_id, _action, _changes), do: :ok
        @impl true
        def list_flow_node_instances(_id), do: {:ok, []}
        @impl true
        def finish_fni_with_data_objects(_id, _changes, _intents), do: {:ok, %{writes: []}}
        @impl true
        def write_data_object(_params),
          do: {:ok, %{write_id: "noop", created_at: DateTime.utc_now()}}

        @impl true
        def list_data_objects(_id), do: {:ok, []}
        @impl true
        def get_process_instance_for_retry(_id), do: {:error, :not_found}
        @impl true
        def list_all_flow_node_instances(_id), do: {:ok, []}
        @impl true
        def execute_retry_reset(_id, _opts), do: {:ok, []}
        @impl true
        def revert_retry(_id, _state, _finished_at), do: :ok
        @impl true
        def list_child_process_instances(_), do: {:ok, []}
        @impl true
        def patch_fni_type_properties(_, _), do: :ok
        @impl true
        def create_gateway_pending_arrival(_params), do: :ok
        @impl true
        def list_gateway_pending_arrivals(_process_instance_id), do: {:ok, []}
        @impl true
        def delete_gateway_pending_arrivals_for_gateway(_fni_id), do: :ok
      end

      Application.put_env(:core_execution, :persistence_adapter, FailingCleanupAdapter)

      assert {:ok, 0} = ResumeRunner.resume_all()
    end
  end

  describe "ResumeRunner with populated adapter" do
    @resume_version_id "00000000-0000-0000-0000-000000000099"

    setup do
      ModelCache.reset_state()
      Application.put_env(:core_execution, :persistence_adapter, ConfigurableResumeAdapter)

      on_exit(fn ->
        Application.delete_env(:core_execution, :resume_test_fixture)

        Application.put_env(
          :core_execution,
          :persistence_adapter,
          EvilEngine.Execution.Persistence.NoOp
        )

        ModelCache.reset_state()
      end)

      :ok
    end

    test "resumes PI with only finished FNIs and keeps terminal FNIs in memory" do
      process_instance_id = random_id()
      definitions = BpmnFactory.linear_three_node()
      ModelCache.put_new(@resume_version_id, definitions)

      Application.put_env(:core_execution, :resume_test_fixture, %{
        records: [
          %{
            id: process_instance_id,
            process_version_id: @resume_version_id,
            business_key: nil,
            parent_process_instance_id: nil,
            triggerer_flow_node_instance_id: nil,
            started_at: DateTime.utc_now(),
            started_by: %{"id" => "test-user"},
            started_with_context: %{"input" => "data"}
          }
        ],
        list_flow_node_instances:
          {:ok,
           [
             %{
               id: "fni-start",
               flow_node_id: "Start_1",
               flow_node_type: "start_event",
               state: "finished",
               input_token: %{"input" => "data"},
               type_properties: %{},
               previous_flow_node_instance_ids: [],
               lane_name: nil,
               started_at: DateTime.utc_now()
             },
             %{
               id: "fni-task",
               flow_node_id: "Task_1",
               flow_node_type: "task",
               state: "finished",
               input_token: %{"input" => "data"},
               type_properties: %{},
               previous_flow_node_instance_ids: ["fni-start"],
               lane_name: nil,
               started_at: DateTime.utc_now()
             },
             %{
               id: "fni-end",
               flow_node_id: "End_1",
               flow_node_type: "end_event",
               state: "finished",
               input_token: %{"input" => "data"},
               type_properties: %{},
               previous_flow_node_instance_ids: ["fni-task"],
               lane_name: nil,
               started_at: DateTime.utc_now()
             }
           ]}
      })

      assert {:ok, 1} = ResumeRunner.resume_all()

      assert {:ok, process_instance_pid} = Execution.lookup_process_instance(process_instance_id)
      assert Process.alive?(process_instance_pid)

      {:running, state} = :sys.get_state(process_instance_pid)
      assert state.started_with_context == %{"input" => "data"}
      assert state.process_model.id == "test-process"

      assert Enum.all?(state.flow_node_instance_states, fn {_id, entry} ->
               entry.state == :finished
             end)

      DynamicSupervisor.terminate_child(EvilEngine.Execution.Supervisor, process_instance_pid)
    end

    test "publishes EngineOverloaded when resume exceeds a finite cap" do
      original_limit = Application.get_env(:core_execution, :max_concurrent_process_instances)
      Application.put_env(:core_execution, :max_concurrent_process_instances, 0)

      on_exit(fn ->
        if original_limit do
          Application.put_env(:core_execution, :max_concurrent_process_instances, original_limit)
        else
          Application.delete_env(:core_execution, :max_concurrent_process_instances)
        end
      end)

      process_instance_id = random_id()
      definitions = BpmnFactory.linear_three_node()
      ModelCache.put_new(@resume_version_id, definitions)

      Application.put_env(:core_execution, :resume_test_fixture, %{
        records: [
          %{
            id: process_instance_id,
            process_version_id: @resume_version_id,
            business_key: nil,
            parent_process_instance_id: nil,
            triggerer_flow_node_instance_id: nil,
            started_at: DateTime.utc_now(),
            started_by: %{"id" => "test-user"},
            started_with_context: %{"input" => "data"}
          }
        ],
        list_flow_node_instances:
          {:ok,
           [
             %{
               id: "fni-start",
               flow_node_id: "Start_1",
               flow_node_type: "start_event",
               state: "finished",
               input_token: %{"input" => "data"},
               type_properties: %{},
               previous_flow_node_instance_ids: [],
               lane_name: nil,
               started_at: DateTime.utc_now()
             }
           ]}
      })

      sink_name = "resume-overload-#{System.unique_integer([:positive])}"

      assert :ok =
               EngineEventBus.register_sink(sink_name, ResumeOverloadSink, test_pid: self())

      assert {:ok, 1} = ResumeRunner.resume_all()

      assert_receive {:resume_overload, %Event.EngineOverloaded{level: :critical, limit: 0}}, 1_000

      assert {:ok, process_instance_pid} = Execution.lookup_process_instance(process_instance_id)
      DynamicSupervisor.terminate_child(EvilEngine.Execution.Supervisor, process_instance_pid)
    end

    test "returns zero resumed count when FNI load fails" do
      definitions = BpmnFactory.linear_three_node()
      ModelCache.put_new(@resume_version_id, definitions)

      Application.put_env(:core_execution, :resume_test_fixture, %{
        records: [
          %{
            id: "pi-missing-fn-is",
            process_version_id: @resume_version_id,
            started_at: DateTime.utc_now(),
            started_by: %{"id" => "test-user"},
            started_with_context: %{}
          }
        ],
        list_flow_node_instances: {:error, :not_found}
      })

      assert {:ok, 0} = ResumeRunner.resume_all()
    end

    test "does not double-count when the same PI is already running" do
      process_instance_id = random_id()
      flow_node_instance_id = random_id()

      flow_node_instance_data = [
        %{
          id: flow_node_instance_id,
          flow_node_id: "UserTask_1",
          flow_node_type: "user_task",
          state: "waiting",
          input_token: %{"input" => "data"},
          type_properties: %{},
          previous_flow_node_instance_ids: [],
          lane_name: nil,
          started_at: DateTime.utc_now()
        }
      ]

      definitions = BpmnFactory.user_task_process()
      ModelCache.put_new(@resume_version_id, definitions)

      assert {:ok, _running_pid} =
               resume_pi(process_instance_id, @resume_version_id, flow_node_instance_data)

      Application.put_env(:core_execution, :resume_test_fixture, %{
        records: [
          %{
            id: process_instance_id,
            process_version_id: @resume_version_id,
            started_at: DateTime.utc_now(),
            started_by: %{"id" => "test-user"},
            started_with_context: %{"input" => "data"}
          }
        ],
        list_flow_node_instances:
          {:ok,
           [
             %{
               id: flow_node_instance_id,
               flow_node_id: "UserTask_1",
               flow_node_type: "user_task",
               state: "waiting",
               input_token: %{"input" => "data"},
               type_properties: %{},
               previous_flow_node_instance_ids: [],
               lane_name: nil,
               started_at: DateTime.utc_now()
             }
           ]}
      })

      assert {:ok, 0} = ResumeRunner.resume_all()
      assert {:ok, _pid} = Execution.lookup_process_instance(process_instance_id)
    end
  end

  # -------------------------------------------------------------------
  # EBG: Resume with waiting catches after Event-Based Gateway
  # -------------------------------------------------------------------

  describe "EBG: Resume with multiple waiting catches" do
    setup do
      Scheduler.reset_state()
      on_exit(fn -> Scheduler.reset_state() end)
    end

    test "both waiting catches are rehydrated; PI enters running state" do
      definitions =
        BpmnFactory.event_based_gateway_timer_message_process(
          time_duration: "PT30S",
          message_name: "resume-msg"
        )

      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()
      ebg_fni_id = random_id()
      timer_fni_id = random_id()
      message_fni_id = random_id()

      flow_node_instance_data = [
        %{
          id: ebg_fni_id,
          flow_node_id: "EBG_1",
          flow_node_type: "event_based_gateway",
          state: "finished",
          input_token: %{},
          type_properties: %{},
          previous_flow_node_instance_ids: [],
          lane_name: nil,
          started_at: DateTime.utc_now()
        },
        %{
          id: timer_fni_id,
          flow_node_id: "TimerCatch_1",
          flow_node_type: "intermediate_catch_event",
          state: "waiting",
          input_token: %{},
          type_properties: %{},
          previous_flow_node_instance_ids: [ebg_fni_id],
          lane_name: nil,
          started_at: DateTime.utc_now()
        },
        %{
          id: message_fni_id,
          flow_node_id: "MessageCatch_1",
          flow_node_type: "intermediate_catch_event",
          state: "waiting",
          input_token: %{},
          type_properties: %{},
          previous_flow_node_instance_ids: [ebg_fni_id],
          lane_name: nil,
          started_at: DateTime.utc_now()
        }
      ]

      assert {:ok, process_instance_pid} =
               resume_pi(process_instance_id, @version_id, flow_node_instance_data)

      Process.sleep(200)
      assert Process.alive?(process_instance_pid)

      {:running, state} = :sys.get_state(process_instance_pid)

      waiting_fnis =
        state.flow_node_instance_states
        |> Enum.filter(fn {_id, entry} -> entry.state in [:waiting, :active] end)

      assert length(waiting_fnis) >= 2

      Execution.abort_process_instance(
        process_instance_id,
        "cleanup",
        %Identity{id: "cleanup"}
      )
    end
  end

  describe "EBG: Resume with Receive Task as EBG successor" do
    setup do
      Scheduler.reset_state()
      on_exit(fn -> Scheduler.reset_state() end)
    end

    test "waiting Receive Task and Timer are rehydrated; PI enters running state" do
      definitions =
        BpmnFactory.event_based_gateway_receive_task_timer_process(
          time_duration: "PT30S",
          message_name: "resume-recv"
        )

      ModelCache.put_new(@version_id, definitions)
      MessageSubscriptions.mark_ready()

      process_instance_id = random_id()
      ebg_fni_id = random_id()
      recv_fni_id = random_id()
      timer_fni_id = random_id()

      flow_node_instance_data = [
        %{
          id: ebg_fni_id,
          flow_node_id: "EBG_1",
          flow_node_type: "event_based_gateway",
          state: "finished",
          input_token: %{},
          type_properties: %{},
          previous_flow_node_instance_ids: [],
          lane_name: nil,
          started_at: DateTime.utc_now()
        },
        %{
          id: recv_fni_id,
          flow_node_id: "ReceiveTask_1",
          flow_node_type: "receive_task",
          state: "waiting",
          input_token: %{},
          type_properties: %{},
          previous_flow_node_instance_ids: [ebg_fni_id],
          lane_name: nil,
          started_at: DateTime.utc_now()
        },
        %{
          id: timer_fni_id,
          flow_node_id: "TimerCatch_1",
          flow_node_type: "intermediate_catch_event",
          state: "waiting",
          input_token: %{},
          type_properties: %{},
          previous_flow_node_instance_ids: [ebg_fni_id],
          lane_name: nil,
          started_at: DateTime.utc_now()
        }
      ]

      assert {:ok, process_instance_pid} =
               resume_pi(process_instance_id, @version_id, flow_node_instance_data)

      Process.sleep(200)
      assert Process.alive?(process_instance_pid)

      {:running, state} = :sys.get_state(process_instance_pid)

      waiting_fnis =
        state.flow_node_instance_states
        |> Enum.filter(fn {_id, entry} -> entry.state in [:waiting, :active] end)

      assert length(waiting_fnis) >= 2

      Execution.abort_process_instance(
        process_instance_id,
        "cleanup",
        %Identity{id: "cleanup"}
      )
    end
  end

  describe "EBG: Resume with one catch already completed" do
    test "active end event FNI is re-dispatched; PI completes" do
      definitions =
        BpmnFactory.event_based_gateway_timer_message_process(
          time_duration: "PT0S",
          message_name: "resume-completed"
        )

      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()
      ebg_fni_id = random_id()
      timer_fni_id = random_id()
      end_fni_id = random_id()

      flow_node_instance_data = [
        %{
          id: ebg_fni_id,
          flow_node_id: "EBG_1",
          flow_node_type: "event_based_gateway",
          state: "finished",
          input_token: %{},
          type_properties: %{},
          previous_flow_node_instance_ids: [],
          lane_name: nil,
          started_at: DateTime.utc_now()
        },
        %{
          id: timer_fni_id,
          flow_node_id: "TimerCatch_1",
          flow_node_type: "intermediate_catch_event",
          state: "finished",
          input_token: %{},
          type_properties: %{},
          previous_flow_node_instance_ids: [ebg_fni_id],
          lane_name: nil,
          started_at: DateTime.utc_now()
        },
        %{
          id: end_fni_id,
          flow_node_id: "End_1",
          flow_node_type: "end_event",
          state: "active",
          input_token: %{},
          type_properties: %{},
          previous_flow_node_instance_ids: [timer_fni_id],
          lane_name: nil,
          started_at: DateTime.utc_now()
        }
      ]

      assert {:ok, process_instance_pid} =
               resume_pi(process_instance_id, @version_id, flow_node_instance_data)

      ref = Process.monitor(process_instance_pid)
      assert_receive {:DOWN, ^ref, :process, ^process_instance_pid, _}, 3_000
    end
  end
end

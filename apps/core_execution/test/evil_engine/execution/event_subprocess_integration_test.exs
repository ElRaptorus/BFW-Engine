defmodule EvilEngine.Execution.EventSubprocessIntegrationTest do
  @moduledoc """
  Integration tests for Event Subprocess (`<bpmn:subProcess triggeredByEvent="true">`)
  runtime execution (Phase 5).

  Covers, per trigger type and interrupting/non-interrupting variant:
  - Message / Signal / Timer / Error / Escalation / Conditional triggers
  - Interrupting: cancels the scope's other work, runs the ESP, scope finishes
  - Non-interrupting: runs in parallel, may fire multiple times, scope waits for
    both the main flow and every ESP child
  - Reactive error/escalation resolution (specific vs catch-all)
  - Structural richness (ESP body with embedded subprocess, nested ESP)
  - Two ESPs in one scope; only the matching trigger fires
  - Interrupting ESP cancels a running non-interrupting ESP instance
  - Lifecycle: abort + fatal cascade to the ESP child PI
  - Sanity/bad paths: interrupting ESP does not kill the scope PI; dormant
    trigger never fires; idempotent interrupting fire; non-modeled error not
    caught by an ESP error start

  Triggers whose source is external (message/signal/timer) are driven by sending
  the scope PI the same internal message its subscription/scheduler would
  (`{:event_subprocess_message, ...}`, `{:event_subprocess_signal, ...}`,
  `{:timer_fired, ..., %{kind: :event_subprocess_start}}`). The subscription
  wiring itself is covered by
  `EvilEngine.Events.EventSubprocessSubscriptionTest`.
  """
  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Model.EscalationDefinition
  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.MessageDefinition
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.BPMN.Model.SignalDefinition
  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Events.MessageSubscriptions
  alias EvilEngine.Events.SignalSubscriptions
  alias EvilEngine.Execution
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Types.Identity

  @version_id "esp-test-version-001"
  @identity %Identity{id: "test-user", roles: ["admin"], groups: []}

  setup do
    Application.put_env(
      :core_execution,
      :persistence_adapter,
      EvilEngine.Execution.Persistence.NoOp
    )

    ModelCache.reset_state()
    MessageSubscriptions.reset_state()
    SignalSubscriptions.reset_state()

    ref = make_ref()
    subscribe_events(ref)

    on_exit(fn ->
      unsubscribe_events(ref)
      Application.delete_env(:core_execution, :persistence_adapter)
      ModelCache.reset_state()
      MessageSubscriptions.reset_state()
      SignalSubscriptions.reset_state()
    end)

    {:ok, ref: ref}
  end

  # ===================================================================
  # Message-triggered ESP
  # ===================================================================

  describe "message-triggered ESP" do
    test "interrupting: cancels the main branch, runs the ESP, scope finishes", %{ref: ref} do
      deploy(build_scope([message_esp("ESP_Msg", "esp-msg", true, :task)]))
      {pid, parent_id} = start_scope()

      main_fni = await_user_task_fni(ref, parent_id)

      send(pid, {:event_subprocess_message, "ESP_Msg", %{}})

      assert_receive {:sp_child_started, ^ref,
                      %{parent_process_instance_id: ^parent_id, child_process_instance_id: child}},
                     3_000

      assert_finished(ref, child)
      assert_interrupted(ref, main_fni)
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end

    test "non-interrupting: ESP runs in parallel; scope waits for the main flow", %{ref: ref} do
      deploy(build_scope([message_esp("ESP_Msg", "esp-msg", false, :task)]))
      {pid, parent_id} = start_scope()
      main_fni = await_user_task_fni(ref, parent_id)

      send(pid, {:event_subprocess_message, "ESP_Msg", %{}})

      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child}}, 3_000
      assert_finished(ref, child)

      # The main user task is still waiting → scope must not be finished yet.
      refute_receive {:pi_state, ^ref, %{process_instance_id: ^parent_id, new_state: :finished}},
                     300

      :ok = ProcessInstance.finish_user_task(pid, main_fni, %{}, @identity)
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end

    test "non-interrupting fires twice → two concurrent ESP child instances", %{ref: ref} do
      deploy(build_scope([message_esp("ESP_Msg", "esp-msg", false, :task)]))
      {pid, parent_id} = start_scope()
      main_fni = await_user_task_fni(ref, parent_id)

      send(pid, {:event_subprocess_message, "ESP_Msg", %{}})
      send(pid, {:event_subprocess_message, "ESP_Msg", %{}})

      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child_one}}, 3_000
      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child_two}}, 3_000
      assert child_one != child_two

      assert_finished(ref, child_one)
      assert_finished(ref, child_two)

      :ok = ProcessInstance.finish_user_task(pid, main_fni, %{}, @identity)
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end

    test "trigger payload flows through to the ESP child", %{ref: ref} do
      deploy(build_scope([message_esp("ESP_Msg", "esp-msg", true, :task)]))
      {pid, parent_id} = start_scope()
      _main_fni = await_user_task_fni(ref, parent_id)

      send(pid, {:event_subprocess_message, "ESP_Msg", %{"claim" => "abc"}})

      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child}}, 3_000
      assert_finished(ref, child)
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end
  end

  # ===================================================================
  # Signal-triggered ESP
  # ===================================================================

  describe "signal-triggered ESP" do
    test "interrupting signal ESP cancels main and finishes scope", %{ref: ref} do
      deploy(build_scope([signal_esp("ESP_Sig", "esp-sig", true, :task)]))
      {pid, parent_id} = start_scope()
      main_fni = await_user_task_fni(ref, parent_id)

      send(pid, {:event_subprocess_signal, "ESP_Sig"})

      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child}}, 3_000
      assert_finished(ref, child)
      assert_interrupted(ref, main_fni)
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end

    test "non-interrupting signal ESP fires multiple times", %{ref: ref} do
      deploy(build_scope([signal_esp("ESP_Sig", "esp-sig", false, :task)]))
      {pid, parent_id} = start_scope()
      main_fni = await_user_task_fni(ref, parent_id)

      send(pid, {:event_subprocess_signal, "ESP_Sig"})
      send(pid, {:event_subprocess_signal, "ESP_Sig"})

      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child_one}}, 3_000
      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child_two}}, 3_000
      assert_finished(ref, child_one)
      assert_finished(ref, child_two)

      :ok = ProcessInstance.finish_user_task(pid, main_fni, %{}, @identity)
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end
  end

  # ===================================================================
  # Timer-triggered ESP
  # ===================================================================

  describe "timer-triggered ESP" do
    test "interrupting timer (duration) ESP cancels main and finishes scope", %{ref: ref} do
      event_def = %EventDefinition.Timer{time_duration: "PT1H"}
      deploy(build_scope([typed_esp("ESP_Timer", event_def, true, :task)]))
      {pid, parent_id} = start_scope()
      main_fni = await_user_task_fni(ref, parent_id)

      send(pid, timer_fired_message("ESP_Timer"))

      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child}}, 3_000
      assert_finished(ref, child)
      assert_interrupted(ref, main_fni)
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end

    test "non-interrupting timer ESP runs in parallel", %{ref: ref} do
      event_def = %EventDefinition.Timer{time_duration: "PT1H"}
      deploy(build_scope([typed_esp("ESP_Timer", event_def, false, :task)]))
      {pid, parent_id} = start_scope()
      main_fni = await_user_task_fni(ref, parent_id)

      send(pid, timer_fired_message("ESP_Timer"))

      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child}}, 3_000
      assert_finished(ref, child)

      :ok = ProcessInstance.finish_user_task(pid, main_fni, %{}, @identity)
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end

    test "cyclic non-interrupting timer ESP fires on each tick (scope re-arms)", %{ref: ref} do
      # A cyclic timer's recurrence is owned by the scope (rearm_cycle_timer/4),
      # not the child; each scheduler tick spawns a fresh child whose timer start
      # passes through. Two ticks → two independent child instances.
      event_def = %EventDefinition.Timer{time_cycle: "R/PT1H"}
      deploy(build_scope([typed_esp("ESP_Cycle", event_def, false, :task)]))
      {pid, parent_id} = start_scope()
      main_fni = await_user_task_fni(ref, parent_id)

      send(pid, timer_fired_message("ESP_Cycle"))
      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child_one}}, 3_000
      assert_finished(ref, child_one)

      send(pid, timer_fired_message("ESP_Cycle"))
      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child_two}}, 3_000
      assert_finished(ref, child_two)

      refute child_one == child_two

      :ok = ProcessInstance.finish_user_task(pid, main_fni, %{}, @identity)
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end
  end

  # ===================================================================
  # Conditional-triggered ESP
  # ===================================================================

  describe "conditional-triggered ESP" do
    test "interrupting conditional ESP fires when the condition holds", %{ref: ref} do
      event_def = %EventDefinition.Conditional{condition_expression: "true"}
      deploy(build_scope([typed_esp("ESP_Cond", event_def, true, :task)]))
      {pid, parent_id} = start_scope()

      # Condition "true" fires on the first conditional evaluation (edge false→true)
      # right after the scope's initial dispatch — no external stimulus needed.
      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child}}, 3_000
      assert_finished(ref, child)
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end

    test "conditional ESP stays dormant while its condition is false", %{ref: ref} do
      event_def = %EventDefinition.Conditional{condition_expression: "false"}
      deploy(build_scope([typed_esp("ESP_Cond", event_def, false, :task)]))
      {pid, parent_id} = start_scope()
      main_fni = await_user_task_fni(ref, parent_id)

      refute_received {:sp_child_started, ^ref, %{subprocess_node_id: "ESP_Cond"}}

      :ok = ProcessInstance.finish_user_task(pid, main_fni, %{}, @identity)
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end
  end

  # ===================================================================
  # Error-triggered ESP (reactive)
  # ===================================================================

  describe "error-triggered ESP" do
    test "modeled error caught by the ESP error start; scope finishes (not fatal)", %{ref: ref} do
      event_def = %EventDefinition.Error{error_code: "E1"}
      deploy(build_scope([typed_esp("ESP_Err", event_def, true, :task)]))
      {pid, parent_id} = start_scope()
      main_fni = await_user_task_fni(ref, parent_id)

      send(pid, {:fni_result, main_fni, {:error, %{error_code: "E1", error_message: "boom"}}})

      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child}}, 3_000
      assert_finished(ref, child)
      assert_finished(ref, parent_id)
      refute_received {:pi_state, ^ref, %{process_instance_id: ^parent_id, new_state: :fatal}}
      await_process_death(pid)
    end

    test "specific error code beats a catch-all ESP error start", %{ref: ref} do
      specific = typed_esp("ESP_Specific", %EventDefinition.Error{error_code: "E1"}, true, :task)
      catch_all = typed_esp("ESP_CatchAll", %EventDefinition.Error{error_code: nil}, true, :task)

      deploy(build_scope([specific, catch_all]))
      {pid, parent_id} = start_scope()
      main_fni = await_user_task_fni(ref, parent_id)

      send(pid, {:fni_result, main_fni, {:error, %{error_code: "E1", error_message: "boom"}}})

      assert_receive {:sp_child_started, ^ref, %{subprocess_node_id: fired}}, 3_000
      assert fired == "ESP_Specific"
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end

    test "non-modeled (atom) error is NOT caught by an ESP error start → scope fatal", %{ref: ref} do
      event_def = %EventDefinition.Error{error_code: "E1"}
      deploy(build_scope([typed_esp("ESP_Err", event_def, true, :task)]))
      {pid, parent_id} = start_scope()
      main_fni = await_user_task_fni(ref, parent_id)

      send(pid, {:fni_result, main_fni, {:error, :some_engine_failure}})

      assert_receive {:pi_state, ^ref, %{process_instance_id: ^parent_id, new_state: :fatal}},
                     3_000

      refute_received {:sp_child_started, ^ref, %{subprocess_node_id: "ESP_Err"}}
      await_process_death(pid)
    end
  end

  # ===================================================================
  # Escalation-triggered ESP (reactive, via a main-flow throw)
  # ===================================================================

  describe "escalation-triggered ESP" do
    test "non-interrupting escalation ESP fires on a main-flow escalation throw", %{ref: ref} do
      event_def = %EventDefinition.Escalation{escalation_code: "ESC1"}
      esp = typed_esp("ESP_Esc", event_def, false, :task)
      deploy(build_scope_escalation_throw([esp], "ESC1"))
      {pid, parent_id} = start_scope()

      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child}}, 3_000
      assert_finished(ref, child)
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end

    test "escalation resolved via a global escalation definition (escalation_ref)", %{ref: ref} do
      # Both the throw and the ESP start reference the global <bpmn:escalation>
      # (id "Esc_ESP", code "ESC1"); the codes must reconcile through the ref path.
      event_def = %EventDefinition.Escalation{escalation_ref: "Esc_ESP"}
      esp = typed_esp("ESP_EscRef", event_def, false, :task)

      deploy(
        build_scope_escalation_throw_with(
          [esp],
          %EventDefinition.Escalation{escalation_ref: "Esc_ESP"}
        )
      )

      {pid, parent_id} = start_scope()

      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child}}, 3_000
      assert_finished(ref, child)
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end

    test "catch-all escalation ESP (no code) catches any thrown escalation", %{ref: ref} do
      esp =
        typed_esp("ESP_EscAny", %EventDefinition.Escalation{escalation_code: nil}, false, :task)

      deploy(build_scope_escalation_throw([esp], "ESC_WHATEVER"))
      {pid, parent_id} = start_scope()

      assert_receive {:sp_child_started, ^ref, %{subprocess_node_id: "ESP_EscAny"}}, 3_000
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end

    test "interrupting escalation ESP interrupts a waiting main-flow task", %{ref: ref} do
      event_def = %EventDefinition.Escalation{escalation_code: "ESC1"}
      esp = typed_esp("ESP_EscInt", event_def, true, :task)
      deploy(build_scope_escalation_throw_then_wait([esp], "ESC1"))
      {pid, parent_id} = start_scope()

      # The throw fires at start; the escalation is caught by the interrupting ESP,
      # which cancels the just-dispatched main-flow user task. The scope then
      # reaches :finished WITHOUT us ever completing that user task — a
      # non-interrupting ESP would leave the scope blocked on it.
      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child}}, 3_000
      assert_finished(ref, child)

      assert_receive {:fni_state, ^ref,
                      %{
                        process_instance_id: ^parent_id,
                        flow_node_type: :user_task,
                        terminal_state: :interrupted
                      }},
                     5_000

      assert_finished(ref, parent_id)
      await_process_death(pid)
    end
  end

  # ===================================================================
  # Structural richness
  # ===================================================================

  describe "structural richness" do
    test "ESP body containing an embedded subprocess completes", %{ref: ref} do
      deploy(build_scope([message_esp_with_embedded("ESP_Nested", "esp-msg", true)]))
      {pid, parent_id} = start_scope()
      _main_fni = await_user_task_fni(ref, parent_id)

      send(pid, {:event_subprocess_message, "ESP_Nested", %{}})

      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child}}, 3_000
      assert_finished(ref, child)
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end

    test "nested ESP: an inner ESP is scoped to the inner ESP child", %{ref: ref} do
      deploy(build_scope([message_esp_with_inner_esp("ESP_Outer", "esp-msg")]))
      {pid, parent_id} = start_scope()
      _main_fni = await_user_task_fni(ref, parent_id)

      # Fire the outer ESP; its child (which itself declares an inner ESP) runs
      # its main flow to completion without the inner ESP being triggered.
      send(pid, {:event_subprocess_message, "ESP_Outer", %{}})

      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child}}, 3_000
      assert_finished(ref, child)
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end
  end

  # ===================================================================
  # Multiple ESPs in one scope
  # ===================================================================

  describe "multiple ESPs in one scope" do
    test "only the matching trigger fires", %{ref: ref} do
      message = message_esp("ESP_Msg", "esp-msg", true, :task)
      signal = signal_esp("ESP_Sig", "esp-sig", true, :task)
      deploy(build_scope([message, signal]))
      {pid, parent_id} = start_scope()
      _main_fni = await_user_task_fni(ref, parent_id)

      send(pid, {:event_subprocess_message, "ESP_Msg", %{}})

      assert_receive {:sp_child_started, ^ref, %{subprocess_node_id: "ESP_Msg"}}, 3_000
      refute_received {:sp_child_started, ^ref, %{subprocess_node_id: "ESP_Sig"}}
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end

    test "interrupting ESP cancels a running non-interrupting ESP instance", %{ref: ref} do
      non_interrupting = signal_esp("ESP_NonInt", "esp-sig", false, :user_task)
      interrupting = message_esp("ESP_Int", "esp-msg", true, :task)
      deploy(build_scope([non_interrupting, interrupting]))
      {pid, parent_id} = start_scope()
      _main_fni = await_user_task_fni(ref, parent_id)

      # Start a long-running non-interrupting ESP child (its inner user task waits).
      send(pid, {:event_subprocess_signal, "ESP_NonInt"})
      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: non_int_child}}, 3_000

      # Fire the interrupting ESP: it interrupts the non-interrupting ESP shell FNI,
      # which cascades an abort to its child PI.
      send(pid, {:event_subprocess_message, "ESP_Int", %{}})
      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: int_child}}, 3_000

      assert_state(ref, non_int_child, :aborted)
      assert_finished(ref, int_child)
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end
  end

  # ===================================================================
  # Lifecycle
  # ===================================================================

  describe "lifecycle" do
    test "abort cascades to a running ESP child PI", %{ref: ref} do
      deploy(build_scope([message_esp("ESP_Msg", "esp-msg", true, :user_task)]))
      {pid, parent_id} = start_scope()
      _main_fni = await_user_task_fni(ref, parent_id)

      send(pid, {:event_subprocess_message, "ESP_Msg", %{}})
      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child}}, 3_000

      :ok = ProcessInstance.abort(pid, "test-abort", @identity)

      assert_state(ref, parent_id, :aborted)
      assert_state(ref, child, :aborted)
      await_process_death(pid)
    end

    test "force_fatal on the scope cascades a fatal to the ESP child PI", %{ref: ref} do
      deploy(build_scope([message_esp("ESP_Msg", "esp-msg", true, :user_task)]))
      {pid, parent_id} = start_scope()
      _main_fni = await_user_task_fni(ref, parent_id)

      send(pid, {:event_subprocess_message, "ESP_Msg", %{}})
      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child}}, 3_000

      :ok = ProcessInstance.force_fatal(pid, %{reason: "test-fatal"})

      assert_state(ref, parent_id, :fatal)
      assert_state(ref, child, :fatal)
      await_process_death(pid)
    end
  end

  # ===================================================================
  # Sanity / bad paths
  # ===================================================================

  describe "sanity and bad paths" do
    test "interrupting ESP does not kill the scope PI (reaches :finished)", %{ref: ref} do
      deploy(build_scope([message_esp("ESP_Msg", "esp-msg", true, :task)]))
      {pid, parent_id} = start_scope()
      _main_fni = await_user_task_fni(ref, parent_id)

      send(pid, {:event_subprocess_message, "ESP_Msg", %{}})

      assert_finished(ref, parent_id)
      refute_received {:pi_state, ^ref, %{process_instance_id: ^parent_id, new_state: :aborted}}
      refute_received {:pi_state, ^ref, %{process_instance_id: ^parent_id, new_state: :fatal}}
      await_process_death(pid)
    end

    test "a dormant ESP trigger that never fires does not block the main flow", %{ref: ref} do
      deploy(build_scope([message_esp("ESP_Msg", "esp-msg", true, :task)]))
      {pid, parent_id} = start_scope()
      main_fni = await_user_task_fni(ref, parent_id)

      refute_received {:sp_child_started, ^ref, _}

      :ok = ProcessInstance.finish_user_task(pid, main_fni, %{}, @identity)
      assert_finished(ref, parent_id)
      await_process_death(pid)
    end

    test "two interrupting fires: the first wins, the second is a no-op", %{ref: ref} do
      deploy(build_scope([message_esp("ESP_Msg", "esp-msg", true, :task)]))
      {pid, parent_id} = start_scope()
      _main_fni = await_user_task_fni(ref, parent_id)

      send(pid, {:event_subprocess_message, "ESP_Msg", %{}})
      send(pid, {:event_subprocess_message, "ESP_Msg", %{}})

      assert_receive {:sp_child_started, ^ref, %{child_process_instance_id: child}}, 3_000
      assert_finished(ref, child)
      assert_finished(ref, parent_id)

      # The interrupting fire tore the trigger down; no second child spawned.
      refute_received {:sp_child_started, ^ref, _}

      await_process_death(pid)
    end
  end

  # ===================================================================
  # Helpers: lifecycle
  # ===================================================================

  defp deploy(definitions), do: ModelCache.put_new(@version_id, definitions)

  defp start_scope(opts \\ []) do
    parent_id = opts[:process_instance_id] || random_id()

    {:ok, pid} =
      Execution.start_process_instance(%{
        process_instance_id: parent_id,
        process_version_id: @version_id,
        payload: opts[:payload] || %{},
        identity: @identity
      })

    {pid, parent_id}
  end

  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp await_process_death(pid) do
    mon = Process.monitor(pid)
    assert_receive {:DOWN, ^mon, :process, ^pid, _}, 5_000
  end

  defp timer_fired_message(subprocess_node_id) do
    {:timer_fired, make_ref(),
     %{kind: :event_subprocess_start, subprocess_node_id: subprocess_node_id}}
  end

  # ===================================================================
  # Helpers: assertions
  # ===================================================================

  defp assert_finished(ref, process_instance_id),
    do: assert_state(ref, process_instance_id, :finished)

  defp assert_state(ref, process_instance_id, state) do
    assert_receive {:pi_state, ^ref,
                    %{process_instance_id: ^process_instance_id, new_state: ^state}},
                   5_000
  end

  defp assert_interrupted(ref, flow_node_instance_id) do
    assert_receive {:fni_state, ^ref,
                    %{flow_node_instance_id: ^flow_node_instance_id, terminal_state: :interrupted}},
                   5_000
  end

  # Selective-receive the first user-task FNI state-change for the given scope PI.
  defp await_user_task_fni(ref, process_instance_id, timeout \\ 3_000) do
    receive do
      {:fni_state, ^ref,
       %{
         process_instance_id: ^process_instance_id,
         flow_node_type: :user_task,
         flow_node_instance_id: flow_node_instance_id
       }} ->
        flow_node_instance_id
    after
      timeout -> flunk("no user-task FNI observed for PI #{process_instance_id}")
    end
  end

  # ===================================================================
  # Helpers: telemetry
  # ===================================================================

  defp subscribe_events(ref) do
    test_pid = self()

    :telemetry.attach(
      "esp-pi-state-#{inspect(ref)}",
      [:evil_engine, :process_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:pi_state, ref, metadata})
      end,
      nil
    )

    :telemetry.attach(
      "esp-fni-state-#{inspect(ref)}",
      [:evil_engine, :flow_node_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:fni_state, ref, metadata})
      end,
      nil
    )

    :telemetry.attach(
      "esp-child-started-#{inspect(ref)}",
      [:evil_engine, :subprocess, :child_started],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:sp_child_started, ref, metadata})
      end,
      nil
    )
  end

  defp unsubscribe_events(ref) do
    :telemetry.detach("esp-pi-state-#{inspect(ref)}")
    :telemetry.detach("esp-fni-state-#{inspect(ref)}")
    :telemetry.detach("esp-child-started-#{inspect(ref)}")
  end

  # ===================================================================
  # Helpers: model builders — ESP shells
  # ===================================================================

  defp message_esp(id, _message_name, interrupting, inner_kind) do
    typed_esp(id, %EventDefinition.Message{message_ref: "Msg_ESP"}, interrupting, inner_kind)
  end

  defp signal_esp(id, _signal_name, interrupting, inner_kind) do
    typed_esp(id, %EventDefinition.Signal{signal_ref: "Sig_ESP"}, interrupting, inner_kind)
  end

  # Builds an ESP shell: typed start → activity (task|user_task) → end.
  defp typed_esp(id, event_definition, interrupting, inner_kind) do
    prefix = id

    start = %FlowNode{
      id: prefix <> "_Start",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{
        event_definition: event_definition,
        is_interrupting: interrupting
      },
      outgoing: [prefix <> "_F1"]
    }

    {activity, activity_id} = inner_activity(prefix, inner_kind)

    end_node = %FlowNode{
      id: prefix <> "_End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: [prefix <> "_F2"]
    }

    esp_shell(id, [start, activity, end_node], [
      %SequenceFlow{id: prefix <> "_F1", source_ref: start.id, target_ref: activity_id},
      %SequenceFlow{id: prefix <> "_F2", source_ref: activity_id, target_ref: end_node.id}
    ])
  end

  defp inner_activity(prefix, :task) do
    node = %FlowNode{
      id: prefix <> "_Task",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: [prefix <> "_F1"],
      outgoing: [prefix <> "_F2"]
    }

    {node, node.id}
  end

  defp inner_activity(prefix, :user_task) do
    node = %FlowNode{
      id: prefix <> "_UT",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{},
      incoming: [prefix <> "_F1"],
      outgoing: [prefix <> "_F2"]
    }

    {node, node.id}
  end

  defp message_esp_with_embedded(id, _message_name, interrupting) do
    prefix = id

    start = %FlowNode{
      id: prefix <> "_Start",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{
        event_definition: %EventDefinition.Message{message_ref: "Msg_ESP"},
        is_interrupting: interrupting
      },
      outgoing: [prefix <> "_F1"]
    }

    embedded = %FlowNode{
      id: prefix <> "_Embedded",
      type: :sub_process,
      type_data: %FlowNodeData.SubProcess{
        triggered_by_event: false,
        flow_nodes: [
          %FlowNode{
            id: prefix <> "_Emb_Start",
            type: :start_event,
            type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
            outgoing: [prefix <> "_Emb_F1"]
          },
          %FlowNode{
            id: prefix <> "_Emb_Task",
            type: :task,
            type_data: %FlowNodeData.Task{},
            incoming: [prefix <> "_Emb_F1"],
            outgoing: [prefix <> "_Emb_F2"]
          },
          %FlowNode{
            id: prefix <> "_Emb_End",
            type: :end_event,
            type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
            incoming: [prefix <> "_Emb_F2"]
          }
        ],
        sequence_flows: [
          %SequenceFlow{
            id: prefix <> "_Emb_F1",
            source_ref: prefix <> "_Emb_Start",
            target_ref: prefix <> "_Emb_Task"
          },
          %SequenceFlow{
            id: prefix <> "_Emb_F2",
            source_ref: prefix <> "_Emb_Task",
            target_ref: prefix <> "_Emb_End"
          }
        ]
      },
      incoming: [prefix <> "_F1"],
      outgoing: [prefix <> "_F2"]
    }

    end_node = %FlowNode{
      id: prefix <> "_End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: [prefix <> "_F2"]
    }

    esp_shell(id, [start, embedded, end_node], [
      %SequenceFlow{id: prefix <> "_F1", source_ref: start.id, target_ref: embedded.id},
      %SequenceFlow{id: prefix <> "_F2", source_ref: embedded.id, target_ref: end_node.id}
    ])
  end

  defp message_esp_with_inner_esp(id, _message_name) do
    prefix = id

    start = %FlowNode{
      id: prefix <> "_Start",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{
        event_definition: %EventDefinition.Message{message_ref: "Msg_ESP"},
        is_interrupting: true
      },
      outgoing: [prefix <> "_F1"]
    }

    task = %FlowNode{
      id: prefix <> "_Task",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: [prefix <> "_F1"],
      outgoing: [prefix <> "_F2"]
    }

    end_node = %FlowNode{
      id: prefix <> "_End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: [prefix <> "_F2"]
    }

    # An inner ESP declared inside the outer ESP; it stays dormant here.
    inner_esp =
      typed_esp(prefix <> "_Inner", %EventDefinition.Signal{signal_ref: "Sig_ESP"}, false, :task)

    esp_shell(id, [start, task, end_node, inner_esp], [
      %SequenceFlow{id: prefix <> "_F1", source_ref: start.id, target_ref: task.id},
      %SequenceFlow{id: prefix <> "_F2", source_ref: task.id, target_ref: end_node.id}
    ])
  end

  defp esp_shell(id, flow_nodes, sequence_flows) do
    %FlowNode{
      id: id,
      type: :sub_process,
      type_data: %FlowNodeData.SubProcess{
        triggered_by_event: true,
        flow_nodes: flow_nodes,
        sequence_flows: sequence_flows
      }
    }
  end

  # ===================================================================
  # Helpers: model builders — scope process
  # ===================================================================

  defp build_scope(esp_shells) do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Main_Flow_1"]
    }

    main = %FlowNode{
      id: "Main_UserTask",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{},
      incoming: ["Main_Flow_1"],
      outgoing: ["Main_Flow_2"]
    }

    end_node = %FlowNode{
      id: "End_1",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Main_Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Main_Flow_1", source_ref: "Start_1", target_ref: "Main_UserTask"},
      %SequenceFlow{id: "Main_Flow_2", source_ref: "Main_UserTask", target_ref: "End_1"}
    ]

    wrap_definitions([start, main, end_node] ++ esp_shells, flows)
  end

  defp build_scope_escalation_throw(esp_shells, escalation_code) do
    build_scope_escalation_throw_with(
      esp_shells,
      %EventDefinition.Escalation{escalation_code: escalation_code}
    )
  end

  # Scope main flow: Start → escalation Throw → End. The throw's escalation
  # definition is supplied by the caller (inline code or global ref).
  defp build_scope_escalation_throw_with(esp_shells, throw_event_definition) do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Main_Flow_1"]
    }

    throw_event = %FlowNode{
      id: "Main_Throw",
      type: :intermediate_throw_event,
      type_data: %FlowNodeData.IntermediateThrowEvent{
        event_definition: throw_event_definition
      },
      incoming: ["Main_Flow_1"],
      outgoing: ["Main_Flow_2"]
    }

    end_node = %FlowNode{
      id: "End_1",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Main_Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Main_Flow_1", source_ref: "Start_1", target_ref: "Main_Throw"},
      %SequenceFlow{id: "Main_Flow_2", source_ref: "Main_Throw", target_ref: "End_1"}
    ]

    wrap_definitions([start, throw_event, end_node] ++ esp_shells, flows)
  end

  # Scope main flow: Start → escalation Throw → waiting UserTask → End. Lets an
  # interrupting escalation ESP demonstrably interrupt the waiting main-flow task.
  defp build_scope_escalation_throw_then_wait(esp_shells, escalation_code) do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Main_Flow_1"]
    }

    throw_event = %FlowNode{
      id: "Main_Throw",
      type: :intermediate_throw_event,
      type_data: %FlowNodeData.IntermediateThrowEvent{
        event_definition: %EventDefinition.Escalation{escalation_code: escalation_code}
      },
      incoming: ["Main_Flow_1"],
      outgoing: ["Main_Flow_2"]
    }

    wait = %FlowNode{
      id: "Main_Wait",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{},
      incoming: ["Main_Flow_2"],
      outgoing: ["Main_Flow_3"]
    }

    end_node = %FlowNode{
      id: "End_1",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Main_Flow_3"]
    }

    flows = [
      %SequenceFlow{id: "Main_Flow_1", source_ref: "Start_1", target_ref: "Main_Throw"},
      %SequenceFlow{id: "Main_Flow_2", source_ref: "Main_Throw", target_ref: "Main_Wait"},
      %SequenceFlow{id: "Main_Flow_3", source_ref: "Main_Wait", target_ref: "End_1"}
    ]

    wrap_definitions([start, throw_event, wait, end_node] ++ esp_shells, flows)
  end

  defp wrap_definitions(flow_nodes, sequence_flows) do
    process = %BpmnProcess{
      id: "esp-scope-process",
      name: "ESP Scope Process",
      version: "1.0.0",
      is_executable: true,
      flow_nodes: flow_nodes,
      sequence_flows: sequence_flows
    }

    %Definitions{
      processes: [process],
      messages: [%MessageDefinition{id: "Msg_ESP", name: "esp-msg"}],
      signals: [%SignalDefinition{id: "Sig_ESP", name: "esp-sig"}],
      escalations: [
        %EscalationDefinition{id: "Esc_ESP", name: "esp-esc", escalation_code: "ESC1"}
      ],
      raw_xml: ""
    }
  end
end

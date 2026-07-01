defmodule EvilEngine.Execution.RetryTest do
  @moduledoc """
  Unit tests for the retry orchestration within the core_execution domain.

  Uses the NoOp persistence adapter. Since NoOp stubs return `:not_found`
  for PI reads and `{:ok, []}` for FNI listings, these tests verify:

  - Tree-walk error propagation (ancestor not found)
  - Checkpoint validation (FNI not found)
  - Registry-based running-PI lookup
  - Orchestration path for root PIs vs child PIs

  Happy-path retry semantics (FNI reset, version migration, completion)
  are covered by the integration tests in `test/integration/execution/retry_test.exs`
  where the real persistence adapter and HTTP endpoints are available.
  """
  use ExUnit.Case, async: false

  alias EvilEngine.Execution

  defp build_pi_data(overrides) do
    Map.merge(
      %{
        id: "test-pi-#{System.unique_integer([:positive])}",
        state: "fatal",
        finished_at: DateTime.utc_now(),
        process_version_id: "v1",
        parent_process_instance_id: nil,
        started_by: %{id: "test-user"},
        started_at: DateTime.utc_now(),
        started_with_context: nil,
        business_key: nil,
        triggerer_flow_node_instance_id: nil
      },
      overrides
    )
  end

  defp build_identity do
    %EvilEngine.Types.Identity{id: "test", roles: [], groups: []}
  end

  describe "Execution.retry_process_instance/1 — root PI (no parent)" do
    test "reaches gen_statem start attempt for a root fatal PI" do
      pi_data = build_pi_data(%{parent_process_instance_id: nil})

      result =
        Execution.retry_process_instance(
          pi_data: pi_data,
          resolved_version_id: "v1",
          identity: build_identity(),
          reset_to_flow_node_instance_id: nil
        )

      assert match?({:error, :retry_start_failed, _}, result) or result == :ok,
             "Expected either :ok or {:error, :retry_start_failed, _}, got: #{inspect(result)}"
    end
  end

  describe "Execution.retry_process_instance/1 — tree walk errors" do
    test "returns {:error, :ancestor_not_found, parent_id} when parent does not exist" do
      pi_data =
        build_pi_data(%{parent_process_instance_id: "nonexistent-parent"})

      result =
        Execution.retry_process_instance(
          pi_data: pi_data,
          resolved_version_id: "v1",
          identity: build_identity(),
          reset_to_flow_node_instance_id: nil
        )

      assert {:error, :ancestor_not_found, "nonexistent-parent"} = result
    end
  end

  describe "Execution.retry_process_instance/1 — checkpoint validation" do
    test "returns {:error, :flow_node_instance_not_found, fni_id} for non-existent checkpoint FNI" do
      pi_data = build_pi_data(%{parent_process_instance_id: nil})

      result =
        Execution.retry_process_instance(
          pi_data: pi_data,
          resolved_version_id: "v1",
          identity: build_identity(),
          reset_to_flow_node_instance_id: "nonexistent-fni-id"
        )

      assert {:error, :flow_node_instance_not_found, "nonexistent-fni-id"} = result
    end
  end

  describe "Execution.retry_process_instance/1 — EBG-loser checkpoint guard" do
    test "returns {:error, :retry_checkpoint_is_ebg_loser} for aborted EBG sibling FNI" do
      defmodule EbgLoserAdapter do
        @moduledoc false
        @behaviour EvilEngine.Execution.Persistence

        @impl true
        def create_process_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_process_instance(_, _), do: :ok
        @impl true
        def create_flow_node_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_flow_node_instance(_, _, _), do: :ok
        @impl true
        def list_running_process_instances(_), do: {:ok, %{records: [], next_cursor: nil}}
        @impl true
        def list_flow_node_instances(_), do: {:ok, []}
        @impl true
        def write_data_object(_), do: {:ok, %{write_id: "noop", created_at: DateTime.utc_now()}}
        @impl true
        def finish_fni_with_data_objects(_, _, intents) do
          writes = Enum.map(intents, fn _ -> %{write_id: "noop", created_at: DateTime.utc_now()} end)
          {:ok, %{writes: writes}}
        end
        @impl true
        def list_data_objects(_), do: {:ok, []}
        @impl true
        def cleanup_orphaned_flow_node_instances, do: {:ok, 0}
        @impl true
        def cleanup_orphaned_process_instances, do: {:ok, 0}
        @impl true
        def get_process_instance_for_retry(_), do: {:error, :not_found}
        @impl true
        def list_all_flow_node_instances(_process_instance_id) do
          {:ok,
           [
             %{
               id: "fni-ebg",
               flow_node_id: "EBG_1",
               flow_node_type: "event_based_gateway",
               state: "finished",
               previous_flow_node_instance_ids: ["fni-start"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             },
             %{
               id: "fni-timer-winner",
               flow_node_id: "TimerCatch_1",
               flow_node_type: "intermediate_catch_event",
               state: "finished",
               previous_flow_node_instance_ids: ["fni-ebg"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             },
             %{
               id: "fni-message-loser",
               flow_node_id: "MessageCatch_1",
               flow_node_type: "intermediate_catch_event",
               state: "aborted",
               previous_flow_node_instance_ids: ["fni-ebg"],
               type_properties: %{
                 "reason" => "event_based_gateway_sibling_cancelled",
                 "aborted" => true
               },
               input_token: %{},
               error_info: nil
             }
           ]}
        end

        @impl true
        def execute_retry_reset(_, _), do: {:ok, []}
        @impl true
        def revert_retry(_, _, _), do: :ok
        @impl true
        def list_child_process_instances(_), do: {:ok, []}
        @impl true
        def patch_fni_type_properties(_, _), do: :ok
        @impl true
        def create_gateway_pending_arrival(params), do: {:ok, params}
        @impl true
        def list_gateway_pending_arrivals(_), do: {:ok, []}
        @impl true
        def delete_gateway_pending_arrivals_for_gateway(_), do: :ok
      end

      Application.put_env(:core_execution, :persistence_adapter, EbgLoserAdapter)

      on_exit(fn ->
        Application.delete_env(:core_execution, :persistence_adapter)
      end)

      pi_data = build_pi_data(%{parent_process_instance_id: nil})

      result =
        Execution.retry_process_instance(
          pi_data: pi_data,
          resolved_version_id: "v1",
          identity: build_identity(),
          reset_to_flow_node_instance_id: "fni-message-loser"
        )

      assert {:error, :retry_checkpoint_is_ebg_loser} = result
    end
  end

  describe "Execution.retry_process_instance/1 — join gateway checkpoint guard" do
    test "returns {:error, :retry_checkpoint_is_join_gateway} for parallel gateway FNI" do
      defmodule JoinGatewayAdapter do
        @moduledoc false
        @behaviour EvilEngine.Execution.Persistence

        @impl true
        def create_process_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_process_instance(_, _), do: :ok
        @impl true
        def create_flow_node_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_flow_node_instance(_, _, _), do: :ok
        @impl true
        def list_running_process_instances(_), do: {:ok, %{records: [], next_cursor: nil}}
        @impl true
        def list_flow_node_instances(_), do: {:ok, []}
        @impl true
        def write_data_object(_), do: {:ok, %{write_id: "noop", created_at: DateTime.utc_now()}}
        @impl true
        def finish_fni_with_data_objects(_, _, intents) do
          writes = Enum.map(intents, fn _ -> %{write_id: "noop", created_at: DateTime.utc_now()} end)
          {:ok, %{writes: writes}}
        end
        @impl true
        def list_data_objects(_), do: {:ok, []}
        @impl true
        def cleanup_orphaned_flow_node_instances, do: {:ok, 0}
        @impl true
        def cleanup_orphaned_process_instances, do: {:ok, 0}
        @impl true
        def get_process_instance_for_retry(_), do: {:error, :not_found}
        @impl true
        def list_all_flow_node_instances(_process_instance_id) do
          {:ok,
           [
             %{
               id: "fni-fork",
               flow_node_id: "Fork_1",
               flow_node_type: "parallel_gateway",
               state: "finished",
               previous_flow_node_instance_ids: ["fni-start"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             },
             %{
               id: "fni-join",
               flow_node_id: "Join_1",
               flow_node_type: "parallel_gateway",
               state: "fatal",
               previous_flow_node_instance_ids: ["fni-task-a"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             },
             %{
               id: "fni-task-a",
               flow_node_id: "Task_A",
               flow_node_type: "task",
               state: "finished",
               previous_flow_node_instance_ids: ["fni-fork"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             }
           ]}
        end

        @impl true
        def execute_retry_reset(_, _), do: {:ok, []}
        @impl true
        def revert_retry(_, _, _), do: :ok
        @impl true
        def list_child_process_instances(_), do: {:ok, []}
        @impl true
        def patch_fni_type_properties(_, _), do: :ok
        @impl true
        def create_gateway_pending_arrival(params), do: {:ok, params}
        @impl true
        def list_gateway_pending_arrivals(_), do: {:ok, []}
        @impl true
        def delete_gateway_pending_arrivals_for_gateway(_), do: :ok
      end

      Application.put_env(:core_execution, :persistence_adapter, JoinGatewayAdapter)

      on_exit(fn ->
        Application.delete_env(:core_execution, :persistence_adapter)
      end)

      pi_data = build_pi_data(%{parent_process_instance_id: nil})

      result =
        Execution.retry_process_instance(
          pi_data: pi_data,
          resolved_version_id: "v1",
          identity: build_identity(),
          reset_to_flow_node_instance_id: "fni-join"
        )

      assert {:error, :retry_checkpoint_is_join_gateway} = result
    end
  end

  describe "Execution.retry_process_instance/1 — non-retryable checkpoint guard" do
    test "returns {:error, :retry_checkpoint_is_non_retryable} for host_completed boundary FNI" do
      defmodule NonRetryableAdapter do
        @moduledoc false
        @behaviour EvilEngine.Execution.Persistence

        @impl true
        def create_process_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_process_instance(_, _), do: :ok
        @impl true
        def create_flow_node_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_flow_node_instance(_, _, _), do: :ok
        @impl true
        def list_running_process_instances(_), do: {:ok, %{records: [], next_cursor: nil}}
        @impl true
        def list_flow_node_instances(_), do: {:ok, []}
        @impl true
        def write_data_object(_), do: {:ok, %{write_id: "noop", created_at: DateTime.utc_now()}}
        @impl true
        def finish_fni_with_data_objects(_, _, intents) do
          writes = Enum.map(intents, fn _ -> %{write_id: "noop", created_at: DateTime.utc_now()} end)
          {:ok, %{writes: writes}}
        end
        @impl true
        def list_data_objects(_), do: {:ok, []}
        @impl true
        def cleanup_orphaned_flow_node_instances, do: {:ok, 0}
        @impl true
        def cleanup_orphaned_process_instances, do: {:ok, 0}
        @impl true
        def get_process_instance_for_retry(_), do: {:error, :not_found}
        @impl true
        def list_all_flow_node_instances(_process_instance_id) do
          {:ok,
           [
             %{
               id: "fni-user-task",
               flow_node_id: "UserTask_1",
               flow_node_type: "user_task",
               state: "finished",
               previous_flow_node_instance_ids: ["fni-start"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             },
             %{
               id: "fni-boundary",
               flow_node_id: "BE_Timer",
               flow_node_type: "boundary_event",
               state: "interrupted",
               previous_flow_node_instance_ids: [],
               type_properties: %{
                 "reason" => "host_completed",
                 "interrupted" => true,
                 "host_flow_node_instance_id" => "fni-user-task"
               },
               input_token: %{},
               error_info: nil
             },
             %{
               id: "fni-fatal-task",
               flow_node_id: "Task_DeadEnd",
               flow_node_type: "task",
               state: "fatal",
               previous_flow_node_instance_ids: ["fni-user-task"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             }
           ]}
        end

        @impl true
        def execute_retry_reset(_, _), do: {:ok, []}
        @impl true
        def revert_retry(_, _, _), do: :ok
        @impl true
        def list_child_process_instances(_), do: {:ok, []}
        @impl true
        def patch_fni_type_properties(_, _), do: :ok
        @impl true
        def create_gateway_pending_arrival(params), do: {:ok, params}
        @impl true
        def list_gateway_pending_arrivals(_), do: {:ok, []}
        @impl true
        def delete_gateway_pending_arrivals_for_gateway(_), do: :ok
      end

      Application.put_env(:core_execution, :persistence_adapter, NonRetryableAdapter)

      on_exit(fn ->
        Application.delete_env(:core_execution, :persistence_adapter)
      end)

      pi_data = build_pi_data(%{parent_process_instance_id: nil})

      result =
        Execution.retry_process_instance(
          pi_data: pi_data,
          resolved_version_id: "v1",
          identity: build_identity(),
          reset_to_flow_node_instance_id: "fni-boundary"
        )

      assert {:error, :retry_checkpoint_is_non_retryable} = result
    end
  end

  describe "Execution.retry_process_instance/1 — retry before EBG (7a)" do
    test "checkpoint at a task before the EBG passes the guard" do
      defmodule RetryBeforeEbgAdapter do
        @moduledoc false
        @behaviour EvilEngine.Execution.Persistence

        @impl true
        def create_process_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_process_instance(_, _), do: :ok
        @impl true
        def create_flow_node_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_flow_node_instance(_, _, _), do: :ok
        @impl true
        def list_running_process_instances(_), do: {:ok, %{records: [], next_cursor: nil}}
        @impl true
        def list_flow_node_instances(_), do: {:ok, []}
        @impl true
        def write_data_object(_), do: {:ok, %{write_id: "noop", created_at: DateTime.utc_now()}}
        @impl true
        def finish_fni_with_data_objects(_, _, intents) do
          writes = Enum.map(intents, fn _ -> %{write_id: "noop", created_at: DateTime.utc_now()} end)
          {:ok, %{writes: writes}}
        end
        @impl true
        def list_data_objects(_), do: {:ok, []}
        @impl true
        def cleanup_orphaned_flow_node_instances, do: {:ok, 0}
        @impl true
        def cleanup_orphaned_process_instances, do: {:ok, 0}
        @impl true
        def get_process_instance_for_retry(_), do: {:error, :not_found}
        @impl true
        def list_all_flow_node_instances(_process_instance_id) do
          {:ok,
           [
             %{
               id: "fni-task-before-ebg",
               flow_node_id: "Task_1",
               flow_node_type: "task",
               state: "finished",
               previous_flow_node_instance_ids: ["fni-start"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             },
             %{
               id: "fni-ebg",
               flow_node_id: "EBG_1",
               flow_node_type: "event_based_gateway",
               state: "finished",
               previous_flow_node_instance_ids: ["fni-task-before-ebg"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             }
           ]}
        end

        @impl true
        def execute_retry_reset(_, _), do: {:ok, []}
        @impl true
        def revert_retry(_, _, _), do: :ok
        @impl true
        def list_child_process_instances(_), do: {:ok, []}
        @impl true
        def patch_fni_type_properties(_, _), do: :ok
        @impl true
        def create_gateway_pending_arrival(params), do: {:ok, params}
        @impl true
        def list_gateway_pending_arrivals(_), do: {:ok, []}
        @impl true
        def delete_gateway_pending_arrivals_for_gateway(_), do: :ok
      end

      Application.put_env(:core_execution, :persistence_adapter, RetryBeforeEbgAdapter)

      on_exit(fn ->
        Application.delete_env(:core_execution, :persistence_adapter)
      end)

      pi_data = build_pi_data(%{parent_process_instance_id: nil})

      result =
        Execution.retry_process_instance(
          pi_data: pi_data,
          resolved_version_id: "v1",
          identity: build_identity(),
          reset_to_flow_node_instance_id: "fni-task-before-ebg"
        )

      refute match?({:error, :retry_checkpoint_is_ebg_loser}, result),
             "Checkpoint before EBG should not be rejected as EBG loser"
    end
  end

  describe "Execution.retry_process_instance/1 — retry at downstream fatal (7b)" do
    test "checkpoint at a fatal FNI downstream of EBG winner passes the guard" do
      defmodule RetryDownstreamFatalAdapter do
        @moduledoc false
        @behaviour EvilEngine.Execution.Persistence

        @impl true
        def create_process_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_process_instance(_, _), do: :ok
        @impl true
        def create_flow_node_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_flow_node_instance(_, _, _), do: :ok
        @impl true
        def list_running_process_instances(_), do: {:ok, %{records: [], next_cursor: nil}}
        @impl true
        def list_flow_node_instances(_), do: {:ok, []}
        @impl true
        def write_data_object(_), do: {:ok, %{write_id: "noop", created_at: DateTime.utc_now()}}
        @impl true
        def finish_fni_with_data_objects(_, _, intents) do
          writes = Enum.map(intents, fn _ -> %{write_id: "noop", created_at: DateTime.utc_now()} end)
          {:ok, %{writes: writes}}
        end
        @impl true
        def list_data_objects(_), do: {:ok, []}
        @impl true
        def cleanup_orphaned_flow_node_instances, do: {:ok, 0}
        @impl true
        def cleanup_orphaned_process_instances, do: {:ok, 0}
        @impl true
        def get_process_instance_for_retry(_), do: {:error, :not_found}
        @impl true
        def list_all_flow_node_instances(_process_instance_id) do
          {:ok,
           [
             %{
               id: "fni-ebg",
               flow_node_id: "EBG_1",
               flow_node_type: "event_based_gateway",
               state: "finished",
               previous_flow_node_instance_ids: ["fni-start"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             },
             %{
               id: "fni-timer-winner",
               flow_node_id: "TimerCatch_1",
               flow_node_type: "intermediate_catch_event",
               state: "finished",
               previous_flow_node_instance_ids: ["fni-ebg"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             },
             %{
               id: "fni-message-loser",
               flow_node_id: "MessageCatch_1",
               flow_node_type: "intermediate_catch_event",
               state: "aborted",
               previous_flow_node_instance_ids: ["fni-ebg"],
               type_properties: %{
                 "reason" => "event_based_gateway_sibling_cancelled"
               },
               input_token: %{},
               error_info: nil
             },
             %{
               id: "fni-downstream-fatal",
               flow_node_id: "Script_1",
               flow_node_type: "script_task",
               state: "fatal",
               previous_flow_node_instance_ids: ["fni-timer-winner"],
               type_properties: %{},
               input_token: %{},
               error_info: %{"error_code" => "script_error"}
             }
           ]}
        end

        @impl true
        def execute_retry_reset(_, _), do: {:ok, []}
        @impl true
        def revert_retry(_, _, _), do: :ok
        @impl true
        def list_child_process_instances(_), do: {:ok, []}
        @impl true
        def patch_fni_type_properties(_, _), do: :ok
        @impl true
        def create_gateway_pending_arrival(params), do: {:ok, params}
        @impl true
        def list_gateway_pending_arrivals(_), do: {:ok, []}
        @impl true
        def delete_gateway_pending_arrivals_for_gateway(_), do: :ok
      end

      Application.put_env(:core_execution, :persistence_adapter, RetryDownstreamFatalAdapter)

      on_exit(fn ->
        Application.delete_env(:core_execution, :persistence_adapter)
      end)

      pi_data = build_pi_data(%{parent_process_instance_id: nil})

      result =
        Execution.retry_process_instance(
          pi_data: pi_data,
          resolved_version_id: "v1",
          identity: build_identity(),
          reset_to_flow_node_instance_id: "fni-downstream-fatal"
        )

      refute match?({:error, :retry_checkpoint_is_ebg_loser}, result),
             "Checkpoint at downstream fatal should not be rejected as EBG loser"
    end
  end

  describe "Execution.retry_process_instance/1 — retry at EBG itself (7c)" do
    test "checkpoint at the EBG FNI itself passes the guard" do
      defmodule RetryAtEbgAdapter do
        @moduledoc false
        @behaviour EvilEngine.Execution.Persistence

        @impl true
        def create_process_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_process_instance(_, _), do: :ok
        @impl true
        def create_flow_node_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_flow_node_instance(_, _, _), do: :ok
        @impl true
        def list_running_process_instances(_), do: {:ok, %{records: [], next_cursor: nil}}
        @impl true
        def list_flow_node_instances(_), do: {:ok, []}
        @impl true
        def write_data_object(_), do: {:ok, %{write_id: "noop", created_at: DateTime.utc_now()}}
        @impl true
        def finish_fni_with_data_objects(_, _, intents) do
          writes = Enum.map(intents, fn _ -> %{write_id: "noop", created_at: DateTime.utc_now()} end)
          {:ok, %{writes: writes}}
        end
        @impl true
        def list_data_objects(_), do: {:ok, []}
        @impl true
        def cleanup_orphaned_flow_node_instances, do: {:ok, 0}
        @impl true
        def cleanup_orphaned_process_instances, do: {:ok, 0}
        @impl true
        def get_process_instance_for_retry(_), do: {:error, :not_found}
        @impl true
        def list_all_flow_node_instances(_process_instance_id) do
          {:ok,
           [
             %{
               id: "fni-ebg",
               flow_node_id: "EBG_1",
               flow_node_type: "event_based_gateway",
               state: "finished",
               previous_flow_node_instance_ids: ["fni-start"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             },
             %{
               id: "fni-timer-winner",
               flow_node_id: "TimerCatch_1",
               flow_node_type: "intermediate_catch_event",
               state: "finished",
               previous_flow_node_instance_ids: ["fni-ebg"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             },
             %{
               id: "fni-message-loser",
               flow_node_id: "MessageCatch_1",
               flow_node_type: "intermediate_catch_event",
               state: "aborted",
               previous_flow_node_instance_ids: ["fni-ebg"],
               type_properties: %{
                 "reason" => "event_based_gateway_sibling_cancelled"
               },
               input_token: %{},
               error_info: nil
             }
           ]}
        end

        @impl true
        def execute_retry_reset(_, _), do: {:ok, []}
        @impl true
        def revert_retry(_, _, _), do: :ok
        @impl true
        def list_child_process_instances(_), do: {:ok, []}
        @impl true
        def patch_fni_type_properties(_, _), do: :ok
        @impl true
        def create_gateway_pending_arrival(params), do: {:ok, params}
        @impl true
        def list_gateway_pending_arrivals(_), do: {:ok, []}
        @impl true
        def delete_gateway_pending_arrivals_for_gateway(_), do: :ok
      end

      Application.put_env(:core_execution, :persistence_adapter, RetryAtEbgAdapter)

      on_exit(fn ->
        Application.delete_env(:core_execution, :persistence_adapter)
      end)

      pi_data = build_pi_data(%{parent_process_instance_id: nil})

      result =
        Execution.retry_process_instance(
          pi_data: pi_data,
          resolved_version_id: "v1",
          identity: build_identity(),
          reset_to_flow_node_instance_id: "fni-ebg"
        )

      refute match?({:error, :retry_checkpoint_is_ebg_loser}, result),
             "Checkpoint at EBG itself should not be rejected as EBG loser"
    end
  end

  describe "Execution.retry_process_instance/1 — retry before parallel fork (10a)" do
    test "checkpoint at a task before the fork passes the guard" do
      defmodule RetryBeforeForkAdapter do
        @moduledoc false
        @behaviour EvilEngine.Execution.Persistence

        @impl true
        def create_process_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_process_instance(_, _), do: :ok
        @impl true
        def create_flow_node_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_flow_node_instance(_, _, _), do: :ok
        @impl true
        def list_running_process_instances(_), do: {:ok, %{records: [], next_cursor: nil}}
        @impl true
        def list_flow_node_instances(_), do: {:ok, []}
        @impl true
        def write_data_object(_), do: {:ok, %{write_id: "noop", created_at: DateTime.utc_now()}}
        @impl true
        def finish_fni_with_data_objects(_, _, intents) do
          writes = Enum.map(intents, fn _ -> %{write_id: "noop", created_at: DateTime.utc_now()} end)
          {:ok, %{writes: writes}}
        end
        @impl true
        def list_data_objects(_), do: {:ok, []}
        @impl true
        def cleanup_orphaned_flow_node_instances, do: {:ok, 0}
        @impl true
        def cleanup_orphaned_process_instances, do: {:ok, 0}
        @impl true
        def get_process_instance_for_retry(_), do: {:error, :not_found}
        @impl true
        def list_all_flow_node_instances(_process_instance_id) do
          {:ok,
           [
             %{
               id: "fni-task-before-fork",
               flow_node_id: "Task_1",
               flow_node_type: "task",
               state: "fatal",
               previous_flow_node_instance_ids: ["fni-start"],
               type_properties: %{},
               input_token: %{},
               error_info: %{"error_code" => "some_error"}
             },
             %{
               id: "fni-fork",
               flow_node_id: "Fork_1",
               flow_node_type: "parallel_gateway",
               state: "finished",
               previous_flow_node_instance_ids: ["fni-task-before-fork"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             }
           ]}
        end

        @impl true
        def execute_retry_reset(_, _), do: {:ok, []}
        @impl true
        def revert_retry(_, _, _), do: :ok
        @impl true
        def list_child_process_instances(_), do: {:ok, []}
        @impl true
        def patch_fni_type_properties(_, _), do: :ok
        @impl true
        def create_gateway_pending_arrival(params), do: {:ok, params}
        @impl true
        def list_gateway_pending_arrivals(_), do: {:ok, []}
        @impl true
        def delete_gateway_pending_arrivals_for_gateway(_), do: :ok
      end

      Application.put_env(:core_execution, :persistence_adapter, RetryBeforeForkAdapter)

      on_exit(fn ->
        Application.delete_env(:core_execution, :persistence_adapter)
      end)

      pi_data = build_pi_data(%{parent_process_instance_id: nil})

      result =
        Execution.retry_process_instance(
          pi_data: pi_data,
          resolved_version_id: "v1",
          identity: build_identity(),
          reset_to_flow_node_instance_id: "fni-task-before-fork"
        )

      refute match?({:error, :retry_checkpoint_is_join_gateway}, result),
             "Checkpoint before fork should not be rejected as join gateway"
    end
  end

  describe "Execution.retry_process_instance/1 — retry at downstream fatal after join (10b)" do
    test "checkpoint at a fatal task after join passes the guard" do
      defmodule RetryAfterJoinAdapter do
        @moduledoc false
        @behaviour EvilEngine.Execution.Persistence

        @impl true
        def create_process_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_process_instance(_, _), do: :ok
        @impl true
        def create_flow_node_instance(attributes), do: {:ok, attributes}
        @impl true
        def update_flow_node_instance(_, _, _), do: :ok
        @impl true
        def list_running_process_instances(_), do: {:ok, %{records: [], next_cursor: nil}}
        @impl true
        def list_flow_node_instances(_), do: {:ok, []}
        @impl true
        def write_data_object(_), do: {:ok, %{write_id: "noop", created_at: DateTime.utc_now()}}
        @impl true
        def finish_fni_with_data_objects(_, _, intents) do
          writes = Enum.map(intents, fn _ -> %{write_id: "noop", created_at: DateTime.utc_now()} end)
          {:ok, %{writes: writes}}
        end
        @impl true
        def list_data_objects(_), do: {:ok, []}
        @impl true
        def cleanup_orphaned_flow_node_instances, do: {:ok, 0}
        @impl true
        def cleanup_orphaned_process_instances, do: {:ok, 0}
        @impl true
        def get_process_instance_for_retry(_), do: {:error, :not_found}
        @impl true
        def list_all_flow_node_instances(_process_instance_id) do
          {:ok,
           [
             %{
               id: "fni-fork",
               flow_node_id: "Fork_1",
               flow_node_type: "parallel_gateway",
               state: "finished",
               previous_flow_node_instance_ids: ["fni-start"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             },
             %{
               id: "fni-task-a",
               flow_node_id: "Task_A",
               flow_node_type: "task",
               state: "finished",
               previous_flow_node_instance_ids: ["fni-fork"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             },
             %{
               id: "fni-task-b",
               flow_node_id: "Task_B",
               flow_node_type: "task",
               state: "finished",
               previous_flow_node_instance_ids: ["fni-fork"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             },
             %{
               id: "fni-join",
               flow_node_id: "Join_1",
               flow_node_type: "parallel_gateway",
               state: "finished",
               previous_flow_node_instance_ids: ["fni-task-a", "fni-task-b"],
               type_properties: %{},
               input_token: %{},
               error_info: nil
             },
             %{
               id: "fni-downstream-fatal",
               flow_node_id: "Script_1",
               flow_node_type: "script_task",
               state: "fatal",
               previous_flow_node_instance_ids: ["fni-join"],
               type_properties: %{},
               input_token: %{},
               error_info: %{"error_code" => "script_error"}
             }
           ]}
        end

        @impl true
        def execute_retry_reset(_, _), do: {:ok, []}
        @impl true
        def revert_retry(_, _, _), do: :ok
        @impl true
        def list_child_process_instances(_), do: {:ok, []}
        @impl true
        def patch_fni_type_properties(_, _), do: :ok
        @impl true
        def create_gateway_pending_arrival(params), do: {:ok, params}
        @impl true
        def list_gateway_pending_arrivals(_), do: {:ok, []}
        @impl true
        def delete_gateway_pending_arrivals_for_gateway(_), do: :ok
      end

      Application.put_env(:core_execution, :persistence_adapter, RetryAfterJoinAdapter)

      on_exit(fn ->
        Application.delete_env(:core_execution, :persistence_adapter)
      end)

      pi_data = build_pi_data(%{parent_process_instance_id: nil})

      result =
        Execution.retry_process_instance(
          pi_data: pi_data,
          resolved_version_id: "v1",
          identity: build_identity(),
          reset_to_flow_node_instance_id: "fni-downstream-fatal"
        )

      refute match?({:error, :retry_checkpoint_is_join_gateway}, result),
             "Checkpoint at downstream fatal after join should not be rejected"
    end
  end

  describe "Execution.lookup_process_instance/1" do
    test "returns {:error, :not_found} when PI is not in Registry" do
      assert {:error, :not_found} = Execution.lookup_process_instance("nonexistent-pi")
    end
  end
end

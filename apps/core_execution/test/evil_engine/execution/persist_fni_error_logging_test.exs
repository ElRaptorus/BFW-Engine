defmodule EvilEngine.Execution.PersistFniErrorLoggingTest do
  @moduledoc """
  PF-4 — verifies that the FNI persistence paths in
  `EvilEngine.Execution.ProcessInstance` log adapter errors via
  `log_fni_persist_error/3` instead of silently discarding them.

  With the atomic DOA-write batch design, `finish_fni_with_data_objects`
  failure causes the FNI to go fatal (the DB transaction is rolled back,
  so the FNI never actually finished). The PI then transitions to fatal
  after the first FNI failure, so only one FNI completion is attempted.

  The test verifies that both the combined finish failure and the
  subsequent fatal-persist failure are logged with the adapter's reason.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Execution
  alias EvilEngine.Execution.TestSupport.BpmnFactory
  alias EvilEngine.Types.Identity

  @version_id "00000000-0000-0000-0000-000000000aaa"

  defmodule FailingUpdateAdapter do
    @moduledoc false
    @behaviour EvilEngine.Execution.Persistence

    @impl true
    def create_process_instance(attributes), do: {:ok, attributes}

    @impl true
    def update_process_instance(_id, _changes), do: :ok

    @impl true
    def create_flow_node_instance(attributes), do: {:ok, attributes}

    @impl true
    def update_flow_node_instance(_id, _action, _changes), do: {:error, :db_unavailable}

    @impl true
    def list_running_process_instances(_opts), do: {:ok, %{records: [], next_cursor: nil}}

    @impl true
    def list_flow_node_instances(_id), do: {:ok, []}

    @impl true
    def finish_fni_with_data_objects(_fni_id, _fni_changes, _intents),
      do: {:error, :db_unavailable}

    @impl true
    def write_data_object(_params), do: {:ok, %{write_id: "mock", created_at: DateTime.utc_now()}}

    @impl true
    def list_data_objects(_process_instance_id), do: {:ok, []}

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

  setup do
    Application.put_env(:core_execution, :persistence_adapter, FailingUpdateAdapter)
    Application.put_env(:core_execution, :persistence_retry_max_attempts, 1)
    ModelCache.reset_state()

    # `coverage_runner.exs` sets Logger level to :critical, which suppresses
    # the `Logger.error` calls in `persist_fni_*` BEFORE `capture_log` can
    # see them. Restore the level for these tests.
    previous_level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
      Application.delete_env(:core_execution, :persistence_retry_max_attempts)
      ModelCache.reset_state()
      Logger.configure(level: previous_level)
    end)
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  describe "PF-4: finish_fni_with_data_objects failure logs adapter errors" do
    test "atomic FNI finish failure is logged and FNI goes fatal" do
      definitions = BpmnFactory.linear_three_node()
      ModelCache.put_new(@version_id, definitions)

      log =
        capture_log(fn ->
          opts = %{
            process_instance_id: random_id(),
            process_version_id: @version_id,
            payload: %{"input" => "data"},
            identity: %Identity{id: "test-user", roles: ["admin"], groups: []}
          }

          assert {:ok, pid} = Execution.start_process_instance(opts)

          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
        end)

      # The combined finish fails for the first FNI (Start Event), which
      # triggers a fatal transition. The PI stops, so only one FNI
      # reaches the combined finish path.
      assert log =~ "FNI finish+DO atomic"
      assert log =~ ":db_unavailable"

      # The subsequent persist_fni_fatal also fails and is logged.
      assert log =~ "FNI fatal"
    end
  end

  describe "PF-4: helper accepts both `:ok` and `{:ok, _}` adapter return shapes" do
    # The persistence behaviour signature `update_flow_node_instance/3` returns
    # `:ok | {:error, term()}`, but a defensive helper that also accepts
    # `{:ok, _}` keeps the contract robust against future adapter implementations
    # that might return tagged success tuples.
    test "no log line emitted on successful adapter return" do
      defmodule SuccessAdapter do
        @moduledoc false
        @behaviour EvilEngine.Execution.Persistence

        @impl true
        def create_process_instance(attributes), do: {:ok, attributes}

        @impl true
        def update_process_instance(_id, _changes), do: :ok

        @impl true
        def create_flow_node_instance(attributes), do: {:ok, attributes}

        @impl true
        def update_flow_node_instance(_id, _action, _changes), do: :ok

        @impl true
        def list_running_process_instances(_opts), do: {:ok, %{records: [], next_cursor: nil}}

        @impl true
        def finish_fni_with_data_objects(_fni_id, _fni_changes, intents) do
          now = DateTime.utc_now()
          writes = Enum.map(intents, fn _i -> %{write_id: "mock", created_at: now} end)
          {:ok, %{writes: writes}}
        end

        @impl true
        def list_flow_node_instances(_id), do: {:ok, []}

        @impl true
        def write_data_object(_params),
          do: {:ok, %{write_id: "mock", created_at: DateTime.utc_now()}}

        @impl true
        def list_data_objects(_process_instance_id), do: {:ok, []}

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

      Application.put_env(:core_execution, :persistence_adapter, SuccessAdapter)

      definitions = BpmnFactory.linear_three_node()
      ModelCache.put_new(@version_id, definitions)

      log =
        capture_log(fn ->
          opts = %{
            process_instance_id: random_id(),
            process_version_id: @version_id,
            payload: %{"input" => "data"},
            identity: %Identity{id: "test-user", roles: ["admin"], groups: []}
          }

          assert {:ok, pid} = Execution.start_process_instance(opts)

          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
        end)

      refute log =~ "Failed to persist FNI"
    end
  end
end

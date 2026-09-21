defmodule BfwEngine.Execution.PersistenceFailfastTest do
  @moduledoc """
  Verifies that persistence failures on critical creation writes
  cause fail-fast behavior instead of silent data loss.

  - PI create failure → `start_link` returns `{:error, {:persistence_failed, _}}`
  - FNI create failure → FNI goes fatal (handler never starts), PI goes fatal
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias BfwEngine.BPMN.ModelCache
  alias BfwEngine.Execution
  alias BfwEngine.Execution.TestSupport.BpmnFactory
  alias BfwEngine.Types.Identity

  @version_id "00000000-0000-0000-0000-000000000bbb"

  defmodule FailPiCreateAdapter do
    @moduledoc false
    @behaviour BfwEngine.Execution.Persistence

    @impl true
    def create_process_instance(_attributes), do: {:error, :db_unavailable}

    @impl true
    def update_process_instance(_id, _changes), do: :ok

    @impl true
    def create_flow_node_instance(attributes), do: {:ok, attributes}

    @impl true
    def update_flow_node_instance(_id, _action, _changes), do: :ok

    @impl true
    def list_running_process_instances(_opts), do: {:ok, %{records: [], next_cursor: nil}}

    @impl true
    def list_flow_node_instances(_id), do: {:ok, []}

    @impl true
    def finish_fni_with_data_objects(_fni_id, _fni_changes, intents) do
      now = DateTime.utc_now()
      writes = Enum.map(intents, fn _i -> %{write_id: "mock", created_at: now} end)
      {:ok, %{writes: writes}}
    end

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
    def count_all_flow_node_instances(_id), do: {:ok, 0}

    @impl true
    def get_flow_node_instance_by_id(_id), do: {:error, :not_found}

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

  defmodule FailFniCreateAdapter do
    @moduledoc false
    @behaviour BfwEngine.Execution.Persistence

    @impl true
    def create_process_instance(attributes), do: {:ok, attributes}

    @impl true
    def update_process_instance(_id, _changes), do: :ok

    @impl true
    def create_flow_node_instance(_attributes), do: {:error, :db_unavailable}

    @impl true
    def update_flow_node_instance(_id, _action, _changes), do: :ok

    @impl true
    def list_running_process_instances(_opts), do: {:ok, %{records: [], next_cursor: nil}}

    @impl true
    def list_flow_node_instances(_id), do: {:ok, []}

    @impl true
    def finish_fni_with_data_objects(_fni_id, _fni_changes, intents) do
      now = DateTime.utc_now()
      writes = Enum.map(intents, fn _i -> %{write_id: "mock", created_at: now} end)
      {:ok, %{writes: writes}}
    end

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
    def count_all_flow_node_instances(_id), do: {:ok, 0}

    @impl true
    def get_flow_node_instance_by_id(_id), do: {:error, :not_found}

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
    ModelCache.reset_state()
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

  describe "PI create fail-fast" do
    test "PI start_link fails when create_process_instance exhausts retries" do
      Application.put_env(:core_execution, :persistence_adapter, FailPiCreateAdapter)
      Application.put_env(:core_execution, :persistence_retry_max_attempts, 2)

      definitions = BpmnFactory.linear_three_node()
      ModelCache.put_new(@version_id, definitions)

      log =
        capture_log(fn ->
          result =
            Execution.start_process_instance(%{
              process_instance_id: random_id(),
              process_version_id: @version_id,
              payload: %{"input" => "data"},
              identity: %Identity{id: "test-user", roles: ["admin"], groups: []}
            })

          assert {:error, {:persistence_failed, :db_unavailable}} = result
        end)

      assert log =~ "PI create"
      assert log =~ ":db_unavailable"
    end
  end

  describe "FNI create fail-fast" do
    test "FNI goes fatal when create_flow_node_instance exhausts retries" do
      Application.put_env(:core_execution, :persistence_adapter, FailFniCreateAdapter)
      Application.put_env(:core_execution, :persistence_retry_max_attempts, 2)

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
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
        end)

      assert log =~ "FNI create"
      assert log =~ ":db_unavailable"
    end
  end
end

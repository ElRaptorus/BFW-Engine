defmodule EvilEngine.Execution.FniLifecycleTypePropertiesTest do
  @moduledoc """
  Verifies that FNI terminal-state transitions (fatal, aborted, interrupted)
  merge their metadata into existing type_properties rather than overwriting
  them. This prevents data loss for handler-written properties like
  `child_process_instance_id` on Call Activities, `host_flow_node_instance_id`
  on boundary events, or `async` markers on service tasks.
  """

  use ExUnit.Case, async: false

  alias EvilEngine.Execution.FniLifecycle

  @fni_id "fni-test-00000001"
  @pi_id "pi-test-00000001"

  defmodule RecordingAdapter do
    @moduledoc false
    @behaviour EvilEngine.Execution.Persistence

    @impl true
    def create_process_instance(attributes), do: {:ok, attributes}

    @impl true
    def update_process_instance(_id, _changes), do: :ok

    @impl true
    def create_flow_node_instance(attributes), do: {:ok, attributes}

    @impl true
    def update_flow_node_instance(_id, _action, changes) do
      send(self(), {:fni_update, changes})
      :ok
    end

    @impl true
    def list_running_process_instances(_opts), do: {:ok, %{records: [], next_cursor: nil}}

    @impl true
    def list_flow_node_instances(_id), do: {:ok, []}

    @impl true
    def finish_fni_with_data_objects(_fni_id, _fni_changes, _intents),
      do: {:ok, %{writes: []}}

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

  setup do
    Application.put_env(:core_execution, :persistence_adapter, RecordingAdapter)
    Application.put_env(:core_execution, :persistence_retry_max_attempts, 1)

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
      Application.delete_env(:core_execution, :persistence_retry_max_attempts)
    end)
  end

  describe "transition_to_fatal preserves existing type_properties" do
    test "merges into Call Activity type_properties (child_process_instance_id)" do
      existing = %{
        "child_process_instance_id" => "child-pi-abc123",
        "async" => true
      }

      :ok = FniLifecycle.transition_to_fatal(@fni_id, @pi_id, "child crashed", nil, existing)

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["child_process_instance_id"] == "child-pi-abc123"
      assert type_properties["async"] == true
      assert type_properties["error"] == true
    end

    test "merges into boundary event type_properties (host_flow_node_instance_id)" do
      existing = %{
        "host_flow_node_instance_id" => "host-fni-xyz789",
        "async" => true,
        "fire_at" => "2026-06-14T12:00:00Z"
      }

      :ok = FniLifecycle.transition_to_fatal(@fni_id, @pi_id, "timer crash", nil, existing)

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["host_flow_node_instance_id"] == "host-fni-xyz789"
      assert type_properties["async"] == true
      assert type_properties["fire_at"] == "2026-06-14T12:00:00Z"
      assert type_properties["error"] == true
    end

    test "merges into service task type_properties (async marker)" do
      existing = %{"async" => true}

      :ok = FniLifecycle.transition_to_fatal(@fni_id, @pi_id, "handler crash", nil, existing)

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["async"] == true
      assert type_properties["error"] == true
    end

    test "works with atom-keyed existing type_properties" do
      existing = %{child_process_instance_id: "child-pi-atomkey", async: true}

      :ok = FniLifecycle.transition_to_fatal(@fni_id, @pi_id, "crash", nil, existing)

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["child_process_instance_id"] == "child-pi-atomkey"
      assert type_properties["async"] == true
      assert type_properties["error"] == true
    end

    test "works with empty existing type_properties" do
      :ok = FniLifecycle.transition_to_fatal(@fni_id, @pi_id, "crash", nil, %{})

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["error"] == true
      assert map_size(type_properties) == 1
    end

    test "works with default (no existing type_properties argument)" do
      :ok = FniLifecycle.transition_to_fatal(@fni_id, @pi_id, "crash", nil)

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["error"] == true
      assert map_size(type_properties) == 1
    end
  end

  describe "transition_to_aborted preserves existing type_properties" do
    test "merges into Call Activity type_properties (child_process_instance_id)" do
      existing = %{
        "child_process_instance_id" => "child-pi-abc123",
        "async" => true
      }

      :ok = FniLifecycle.transition_to_aborted(@fni_id, @pi_id, "user_abort", nil, existing)

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["child_process_instance_id"] == "child-pi-abc123"
      assert type_properties["async"] == true
      assert type_properties["aborted"] == true
      assert type_properties["reason"] == "user_abort"
    end

    test "merges into boundary event type_properties (host_flow_node_instance_id)" do
      existing = %{
        "host_flow_node_instance_id" => "host-fni-xyz789",
        "async" => true
      }

      :ok = FniLifecycle.transition_to_interrupted(@fni_id, @pi_id, "host_completed", nil, existing)

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["host_flow_node_instance_id"] == "host-fni-xyz789"
      assert type_properties["async"] == true
      assert type_properties["interrupted"] == true
    end

    test "merges into user task type_properties (require_confirmation)" do
      existing = %{"require_confirmation" => true}

      :ok = FniLifecycle.transition_to_aborted(@fni_id, @pi_id, "process_aborted", nil, existing)

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["require_confirmation"] == true
      assert type_properties["aborted"] == true
    end

    test "works with atom-keyed existing type_properties" do
      existing = %{child_process_instance_id: "child-pi-atomkey", async: true}

      :ok = FniLifecycle.transition_to_aborted(@fni_id, @pi_id, "abort", nil, existing)

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["child_process_instance_id"] == "child-pi-atomkey"
      assert type_properties["async"] == true
      assert type_properties["aborted"] == true
    end

    test "works with empty existing type_properties" do
      :ok = FniLifecycle.transition_to_aborted(@fni_id, @pi_id, "abort", nil, %{})

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["aborted"] == true
      assert type_properties["reason"] == "abort"
    end

    test "works with default (no existing type_properties argument)" do
      :ok = FniLifecycle.transition_to_aborted(@fni_id, @pi_id, "abort", nil)

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["aborted"] == true
    end
  end

  describe "transition_to_interrupted preserves existing type_properties" do
    test "merges into Call Activity type_properties (child_process_instance_id)" do
      existing = %{
        "child_process_instance_id" => "child-pi-abc123",
        "async" => true
      }

      :ok =
        FniLifecycle.transition_to_interrupted(
          @fni_id,
          @pi_id,
          :terminated_by_end_event,
          nil,
          existing
        )

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["child_process_instance_id"] == "child-pi-abc123"
      assert type_properties["async"] == true
      assert type_properties["interrupted"] == true
      assert type_properties["reason"] == :terminated_by_end_event
    end

    test "merges into boundary event type_properties (host_flow_node_instance_id)" do
      existing = %{
        "host_flow_node_instance_id" => "host-fni-xyz789",
        "async" => true
      }

      :ok =
        FniLifecycle.transition_to_interrupted(
          @fni_id,
          @pi_id,
          :boundary_interrupt,
          nil,
          existing
        )

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["host_flow_node_instance_id"] == "host-fni-xyz789"
      assert type_properties["async"] == true
      assert type_properties["interrupted"] == true
    end

    test "merges into service task type_properties (async marker only)" do
      existing = %{"async" => true}

      :ok =
        FniLifecycle.transition_to_interrupted(
          @fni_id,
          @pi_id,
          :terminated_by_end_event,
          nil,
          existing
        )

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["async"] == true
      assert type_properties["interrupted"] == true
    end

    test "works with atom-keyed existing type_properties" do
      existing = %{host_flow_node_instance_id: "host-fni-atomkey"}

      :ok =
        FniLifecycle.transition_to_interrupted(
          @fni_id,
          @pi_id,
          :boundary_interrupt,
          nil,
          existing
        )

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["host_flow_node_instance_id"] == "host-fni-atomkey"
      assert type_properties["interrupted"] == true
    end

    test "works with empty existing type_properties" do
      :ok =
        FniLifecycle.transition_to_interrupted(
          @fni_id,
          @pi_id,
          :terminated_by_end_event,
          nil,
          %{}
        )

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["interrupted"] == true
      assert type_properties["reason"] == :terminated_by_end_event
    end

    test "works with default (no existing type_properties argument)" do
      :ok =
        FniLifecycle.transition_to_interrupted(
          @fni_id,
          @pi_id,
          :terminated_by_end_event,
          nil
        )

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["interrupted"] == true
    end
  end

  describe "terminal metadata wins over existing keys on conflict" do
    test "transition_to_fatal: error flag overwrites if already present" do
      existing = %{"error" => false, "child_process_instance_id" => "child-123"}

      :ok = FniLifecycle.transition_to_fatal(@fni_id, @pi_id, "crash", nil, existing)

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["error"] == true
      assert type_properties["child_process_instance_id"] == "child-123"
    end

    test "transition_to_aborted: aborted flag overwrites if already present" do
      existing = %{"aborted" => false, "child_process_instance_id" => "child-123"}

      :ok = FniLifecycle.transition_to_aborted(@fni_id, @pi_id, "abort", nil, existing)

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["aborted"] == true
      assert type_properties["child_process_instance_id"] == "child-123"
    end

    test "transition_to_interrupted: interrupted flag overwrites if already present" do
      existing = %{"interrupted" => false, "child_process_instance_id" => "child-123"}

      :ok =
        FniLifecycle.transition_to_interrupted(
          @fni_id,
          @pi_id,
          :terminated_by_end_event,
          nil,
          existing
        )

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      assert type_properties["interrupted"] == true
      assert type_properties["child_process_instance_id"] == "child-123"
    end
  end

  describe "all keys are string-keyed in persisted type_properties" do
    test "atom keys from existing properties are stringified" do
      existing = %{
        child_process_instance_id: "child-123",
        async: true,
        custom_metadata: "value"
      }

      :ok = FniLifecycle.transition_to_fatal(@fni_id, @pi_id, "crash", nil, existing)

      assert_receive {:fni_update, changes}
      type_properties = changes.type_properties

      for key <- Map.keys(type_properties) do
        assert is_binary(key), "Expected string key, got: #{inspect(key)}"
      end

      assert type_properties["child_process_instance_id"] == "child-123"
      assert type_properties["async"] == true
      assert type_properties["custom_metadata"] == "value"
      assert type_properties["error"] == true
    end
  end
end

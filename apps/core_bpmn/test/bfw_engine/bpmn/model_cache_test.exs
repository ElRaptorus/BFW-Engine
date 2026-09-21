defmodule BfwEngine.BPMN.ModelCacheTest do
  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.Model.Definitions
  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.MessageDefinition
  alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
  alias BfwEngine.BPMN.Model.SignalDefinition
  alias BfwEngine.BPMN.ModelCache

  # ETS table name used by the single-flight test loader. Created/destroyed
  # in the describe "single-flight" setup block.
  @sf_counter :mc_sf_loader_counter

  # Test loader for single-flight tests. Must be a named module function so
  # it can be passed as {__MODULE__, :counting_loader} to Application.put_env.
  # Increments a call counter in ETS, then sleeps to open a concurrency window
  # so that concurrent callers pile up as waiters.
  def counting_loader(_id) do
    :ets.update_counter(@sf_counter, :calls, 1)
    Process.sleep(30)
    {:error, :simulated_load}
  end

  # Loader that raises an exception — exercises the safe_load/1 rescue clause.
  def raising_loader(_id) do
    raise RuntimeError, "loader exploded"
  end

  # Loader that throws an exit — exercises the safe_load/1 catch :exit clause.
  def exiting_loader(_id) do
    exit(:loader_exit)
  end

  setup do
    ModelCache.reset_state()
    :ok
  end

  defp sample_definitions(tag \\ "test") do
    %Definitions{raw_xml: "<bpmn>#{tag}</bpmn>"}
  end

  # -------------------------------------------------------------------
  # Existing behaviour (unchanged contracts)
  # -------------------------------------------------------------------

  describe "put_new/2 + fetch/1 round-trip" do
    test "stores and retrieves a definitions struct" do
      definitions = sample_definitions()
      assert :ok = ModelCache.put_new("v1", definitions)
      assert {:ok, ^definitions} = ModelCache.fetch("v1")
    end
  end

  describe "put_new/2 idempotency" do
    test "second put_new does not overwrite" do
      defs_a = sample_definitions("a")
      defs_b = sample_definitions("b")

      ModelCache.put_new("v1", defs_a)
      ModelCache.put_new("v1", defs_b)

      assert {:ok, ^defs_a} = ModelCache.fetch("v1")
    end
  end

  describe "fetch/1 on unknown ID" do
    test "returns {:error, :not_found} without loader" do
      assert {:error, :not_found} = ModelCache.fetch("nonexistent")
    end
  end

  describe "get/1" do
    test "returns nil for unknown ID" do
      assert is_nil(ModelCache.get("nonexistent"))
    end

    test "returns definitions for known ID" do
      definitions = sample_definitions()
      ModelCache.put_new("v1", definitions)
      assert %Definitions{} = ModelCache.get("v1")
    end
  end

  describe "delete/1" do
    test "removes cached entry" do
      ModelCache.put_new("v1", sample_definitions())
      assert :ok = ModelCache.delete("v1")
      assert {:error, :not_found} = ModelCache.fetch("v1")
    end
  end

  describe "reset_state/0" do
    test "clears all entries" do
      ModelCache.put_new("v1", sample_definitions("a"))
      ModelCache.put_new("v2", sample_definitions("b"))

      assert :ok = ModelCache.reset_state()
      assert [] = ModelCache.list_cached_ids()
    end
  end

  describe "list_cached_ids/0" do
    test "reflects current cache contents" do
      ModelCache.put_new("v1", sample_definitions("a"))
      ModelCache.put_new("v2", sample_definitions("b"))

      ids = ModelCache.list_cached_ids() |> Enum.sort()
      assert ids == ["v1", "v2"]
    end
  end

  # -------------------------------------------------------------------
  # Single-flight semantics (PF-8)
  # -------------------------------------------------------------------

  describe "single-flight" do
    setup do
      :ets.new(@sf_counter, [:named_table, :public, :set])
      :ets.insert(@sf_counter, {:calls, 0})
      Application.put_env(:core_bpmn, :model_cache_loader, {__MODULE__, :counting_loader})

      on_exit(fn ->
        Application.delete_env(:core_bpmn, :model_cache_loader)
        # Table may already be gone if the test deleted it.
        try do
          :ets.delete(@sf_counter)
        rescue
          ArgumentError -> :ok
        end
      end)

      :ok
    end

    test "N concurrent misses for the same key invoke the loader exactly once" do
      tasks = for _ <- 1..10, do: Task.async(fn -> ModelCache.fetch("sf_key") end)
      results = Task.await_many(tasks, 2000)

      [{:calls, call_count}] = :ets.lookup(@sf_counter, :calls)
      assert call_count == 1, "Expected 1 loader call, got #{call_count}"

      assert Enum.all?(results, &(&1 == {:error, :simulated_load})),
             "All waiters must receive the same result"
    end

    test "error result is propagated identically to all waiters" do
      tasks = for _ <- 1..5, do: Task.async(fn -> ModelCache.fetch("err_key") end)
      results = Task.await_many(tasks, 2000)

      assert length(Enum.uniq(results)) == 1,
             "All #{length(results)} waiters must receive the identical error result"

      assert hd(results) == {:error, :simulated_load}
    end

    test "concurrent misses for different keys each invoke the loader once per key" do
      keys = Enum.map(1..5, &"multi_key_#{&1}")
      tasks = for key <- keys, _ <- 1..4, do: Task.async(fn -> ModelCache.fetch(key) end)
      _results = Task.await_many(tasks, 2000)

      [{:calls, call_count}] = :ets.lookup(@sf_counter, :calls)

      assert call_count == 5,
             "Expected 1 loader call per unique key (5 keys), got #{call_count}"
    end

    test "subsequent fetch after a completed single-flight uses ETS, not the loader" do
      tasks = for _ <- 1..3, do: Task.async(fn -> ModelCache.fetch("post_key") end)
      Task.await_many(tasks, 2000)

      [{:calls, calls_after_first_flight}] = :ets.lookup(@sf_counter, :calls)
      assert calls_after_first_flight == 1

      # The result was an error, so nothing was cached; fetching again calls the loader.
      # This validates that the loader is only skipped when ETS is populated.
      ModelCache.fetch("post_key")

      [{:calls, calls_after_second_fetch}] = :ets.lookup(@sf_counter, :calls)

      assert calls_after_second_fetch == 2,
             "Error results are not cached, so a subsequent fetch should re-invoke the loader"
    end

    test "loader exception is caught and returned as {:error, {:exception, message}}" do
      Application.put_env(:core_bpmn, :model_cache_loader, {__MODULE__, :raising_loader})
      result = ModelCache.fetch("explode_key")
      assert {:error, {:exception, message}} = result
      assert message =~ "loader exploded"
    end

    test "loader exit is caught and returned as {:error, {:exit, reason}}" do
      Application.put_env(:core_bpmn, :model_cache_loader, {__MODULE__, :exiting_loader})
      result = ModelCache.fetch("exit_key")
      assert {:error, {:exit, :loader_exit}} = result
    end
  end

  # -------------------------------------------------------------------
  # Defensive GenServer message handling
  # -------------------------------------------------------------------

  # -------------------------------------------------------------------
  # Start-event indexing isolation (subprocess start isolation)
  #
  # Message/Signal Start Event indexing must only ever surface TOP-LEVEL
  # process start events, never start events nested inside a subprocess
  # (embedded/event/transactional). Otherwise an inner Start Event would be
  # externally triggerable by publishing its message/signal.
  # -------------------------------------------------------------------

  describe "start-event indexing excludes inner subprocess starts" do
    defp definitions_with_inner_event_starts do
      inner_message_start = %FlowNode{
        id: "Inner_Msg_Start",
        type: :start_event,
        type_data: %FlowNodeData.StartEvent{
          event_definition: %EventDefinition.Message{message_ref: "Msg_1"}
        }
      }

      inner_signal_start = %FlowNode{
        id: "Inner_Sig_Start",
        type: :start_event,
        type_data: %FlowNodeData.StartEvent{
          event_definition: %EventDefinition.Signal{signal_ref: "Sig_1"}
        }
      }

      event_subprocess = %FlowNode{
        id: "EventSubProcess_1",
        type: :sub_process,
        type_data: %FlowNodeData.SubProcess{
          triggered_by_event: true,
          flow_nodes: [inner_message_start, inner_signal_start]
        }
      }

      top_message_start = %FlowNode{
        id: "Top_Msg_Start",
        type: :start_event,
        type_data: %FlowNodeData.StartEvent{
          event_definition: %EventDefinition.Message{message_ref: "Msg_1"}
        }
      }

      top_signal_start = %FlowNode{
        id: "Top_Sig_Start",
        type: :start_event,
        type_data: %FlowNodeData.StartEvent{
          event_definition: %EventDefinition.Signal{signal_ref: "Sig_1"}
        }
      }

      process = %BpmnProcess{
        id: "P_isolation",
        is_executable: true,
        flow_nodes: [top_message_start, top_signal_start, event_subprocess]
      }

      %Definitions{
        raw_xml: "",
        processes: [process],
        messages: [%MessageDefinition{id: "Msg_1", name: "order-msg"}],
        signals: [%SignalDefinition{id: "Sig_1", name: "order-sig"}]
      }
    end

    test "find_message_start_events/1 returns only the top-level message start" do
      ModelCache.put_new("v_iso_msg", definitions_with_inner_event_starts())

      start_ids =
        "order-msg"
        |> ModelCache.find_message_start_events()
        |> Enum.map(fn {_process_id, _version_id, start_event_id} -> start_event_id end)

      assert "Top_Msg_Start" in start_ids
      refute "Inner_Msg_Start" in start_ids
    end

    test "find_signal_start_events/1 returns only the top-level signal start" do
      ModelCache.put_new("v_iso_sig", definitions_with_inner_event_starts())

      start_ids =
        "order-sig"
        |> ModelCache.find_signal_start_events()
        |> Enum.map(fn {_process_id, _version_id, start_event_id} -> start_event_id end)

      assert "Top_Sig_Start" in start_ids
      refute "Inner_Sig_Start" in start_ids
    end
  end

  describe "stale / unexpected GenServer messages" do
    test "unknown Task ref in handle_info result tuple is ignored" do
      # Send a fake {ref, result} message directly to the GenServer. This simulates
      # a stale message arriving after reset_state cleared the inflight map.
      ref = make_ref()
      send(Process.whereis(ModelCache), {ref, {:ok, sample_definitions()}})
      # Give the GenServer time to process and verify it hasn't crashed.
      Process.sleep(10)
      assert Process.alive?(Process.whereis(ModelCache))
    end

    test "unknown ref in :DOWN message is ignored" do
      ref = make_ref()
      send(Process.whereis(ModelCache), {:DOWN, ref, :process, self(), :normal})
      Process.sleep(10)
      assert Process.alive?(Process.whereis(ModelCache))
    end
  end
end

defmodule Examples.EventSinks.StructuredLogger.LoggerSinkTest do
  use ExUnit.Case

  alias BfwEngine.Types.Event
  alias Examples.EventSinks.StructuredLogger.LoggerSink

  test "handle_event produces valid JSON with required keys" do
    json_line =
      ExUnit.CaptureIO.capture_io(fn ->
        {:ok, state} = LoggerSink.init(output: :stdout)

        event = %Event.ProcessInstanceStateChanged{
          process_instance_id: "process-instance-1",
          process_model_id: "order",
          version: "1.0.0",
          parent_process_instance_id: nil,
          old_state: :running,
          new_state: :completed,
          occurred_at: ~U[2026-05-14T12:00:00Z]
        }

        assert {:ok, ^state} = LoggerSink.handle_event(event, state)
        LoggerSink.handle_shutdown(state)
      end)

    decoded = Jason.decode!(String.trim(json_line))

    assert Map.has_key?(decoded, "timestamp")
    assert Map.has_key?(decoded, "severity")
    assert Map.has_key?(decoded, "event_type")
    assert decoded["event_type"] == "BfwEngine.Types.Event.ProcessInstanceStateChanged"
    assert decoded["process_instance_id"] == "process-instance-1"
    assert decoded["new_state"] == "completed"
    assert decoded["occurred_at"] == "2026-05-14T12:00:00Z"
  end

  test "severity mapping: SinkFailed and PluginQuarantined are error, EngineOverloaded is warning" do
    overload_json =
      ExUnit.CaptureIO.capture_io(fn ->
        {:ok, state} = LoggerSink.init(output: :stdout)

        assert {:ok, state} =
                 LoggerSink.handle_event(
                   %Event.EngineOverloaded{
                     level: :elevated,
                     active_process_instances: 50,
                     limit: 100,
                     occurred_at: ~U[2026-05-14T12:00:00Z]
                   },
                   state
                 )

        LoggerSink.handle_shutdown(state)
      end)

    assert Jason.decode!(String.trim(overload_json))["severity"] == "warning"

    sink_failed_json =
      ExUnit.CaptureIO.capture_io(fn ->
        {:ok, state} = LoggerSink.init(output: :stdout)

        assert {:ok, state} =
                 LoggerSink.handle_event(
                   %Event.SinkFailed{
                     sink_name: "test_sink",
                     event_kind: Event.EngineStarted,
                     reason: "boom",
                     occurred_at: ~U[2026-05-14T12:01:00Z]
                   },
                   state
                 )

        LoggerSink.handle_shutdown(state)
      end)

    assert Jason.decode!(String.trim(sink_failed_json))["severity"] == "error"

    quarantined_json =
      ExUnit.CaptureIO.capture_io(fn ->
        {:ok, state} = LoggerSink.init(output: :stdout)

        assert {:ok, state} =
                 LoggerSink.handle_event(
                   %Event.PluginQuarantined{
                     plugin_name: "bad_plugin",
                     tier: :inbeam,
                     reason: :on_load_failed,
                     occurred_at: ~U[2026-05-14T12:02:00Z]
                   },
                   state
                 )

        LoggerSink.handle_shutdown(state)
      end)

    assert Jason.decode!(String.trim(quarantined_json))["severity"] == "error"

    info_json =
      ExUnit.CaptureIO.capture_io(fn ->
        {:ok, state} = LoggerSink.init(output: :stdout)

        assert {:ok, state} =
                 LoggerSink.handle_event(
                   %Event.EngineRecovered{
                     previous_level: :elevated,
                     active_process_instances: 10,
                     limit: 1000,
                     occurred_at: ~U[2026-05-14T12:03:00Z]
                   },
                   state
                 )

        LoggerSink.handle_shutdown(state)
      end)

    assert Jason.decode!(String.trim(info_json))["severity"] == "info"
  end

  test "handle_shutdown closes the file device" do
    temporary_directory = System.tmp_dir!()

    log_file_path =
      Path.join(
        temporary_directory,
        "structured_logger_example_#{System.unique_integer([:positive])}.log"
      )

    on_exit(fn -> File.rm(log_file_path) end)

    {:ok, state} = LoggerSink.init(output: log_file_path)

    assert {:ok, state} =
             LoggerSink.handle_event(
               %Event.EngineStarted{
                 engine_id: "engine-1",
                 engine_name: "local",
                 version: "1.0.0",
                 started_at: ~U[2026-05-14T12:00:00Z]
               },
               state
             )

    assert :ok = LoggerSink.handle_shutdown(state)
    assert File.exists?(log_file_path)
    assert String.contains?(File.read!(log_file_path), "BfwEngine.Types.Event.EngineStarted")
  end
end

defmodule EvilEngine.DMN.EvaluatorTelemetryTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias EvilEngine.DMN
  alias EvilEngine.DMN.Evaluator
  alias EvilEngine.DMN.Parser

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "dmns"])
  defp read_fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  defp parse_fixture(name) do
    {:ok, definitions} = Parser.parse(read_fixture(name))
    definitions
  end

  defp await_telemetry_event(event_suffix, predicate, timeout \\ 500) do
    receive do
      {:telemetry_event, [:evil_engine, :dmn, :evaluate, ^event_suffix], measurements, metadata} ->
        if predicate.(metadata) do
          {measurements, metadata}
        else
          await_telemetry_event(event_suffix, predicate, timeout)
        end
    after
      timeout ->
        flunk("expected telemetry #{inspect(event_suffix)} event matching predicate")
    end
  end

  setup do
    test_pid = self()
    handler_id = "test-handler-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:evil_engine, :dmn, :evaluate, :start],
        [:evil_engine, :dmn, :evaluate, :stop],
        [:evil_engine, :dmn, :evaluate, :exception]
      ],
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  describe "evaluate/4 telemetry" do
    test "successful evaluation emits :start then :stop with correct metadata" do
      definitions = parse_fixture("simple_unique.dmn")
      {:ok, _result} = Evaluator.evaluate(definitions, nil, %{"age" => 25})

      {start_measurements, start_metadata} =
        await_telemetry_event(:start, &(&1[:decision_model_id] == nil and not Map.has_key?(&1, :service_id)))

      assert is_integer(start_measurements.system_time)
      assert start_metadata.decision_model_id == nil

      {stop_measurements, stop_metadata} =
        await_telemetry_event(:stop, &(&1[:hit_policy] == :unique))

      assert is_integer(stop_measurements.duration)
      assert stop_metadata.hit_policy == :unique
      assert is_integer(stop_metadata.matched_rule_count)
      assert is_integer(stop_metadata.decision_count)
    end

    test "decision_version_id appears in metadata when passed via opts" do
      definitions = parse_fixture("simple_unique.dmn")
      {:ok, _result} = Evaluator.evaluate(definitions, nil, %{"age" => 25}, decision_version_id: "v-123")

      {_start_measurements, start_metadata} =
        await_telemetry_event(:start, &(&1[:decision_version_id] == "v-123"))

      assert start_metadata.decision_version_id == "v-123"

      {_stop_measurements, stop_metadata} =
        await_telemetry_event(:stop, &(&1[:decision_version_id] == "v-123"))

      assert stop_metadata.decision_version_id == "v-123"
    end

    test "hit_policy is correctly reported for literal expression" do
      definitions = parse_fixture("literal_expression.dmn")
      {:ok, _result} = Evaluator.evaluate(definitions, nil, %{"x" => 10, "y" => 20})

      {_measurements, metadata} =
        await_telemetry_event(:stop, &(&1[:hit_policy] == :literal))

      assert metadata.hit_policy == :literal
    end

    test "matched_rule_count matches trace" do
      definitions = parse_fixture("simple_unique.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"age" => 25})

      {_measurements, metadata} =
        await_telemetry_event(:stop, &(&1[:hit_policy] == :unique))

      assert metadata.matched_rule_count == length(result.matched_rules)
    end

    test "decision_count matches trace decisions" do
      definitions = parse_fixture("simple_unique.dmn")
      {:ok, result} = Evaluator.evaluate(definitions, nil, %{"age" => 25})

      {_measurements, metadata} =
        await_telemetry_event(:stop, &(&1[:hit_policy] == :unique))

      assert metadata.decision_count == length(result.trace.decisions)
    end

    test "failed evaluation (missing required input) emits :start then :stop with error metadata" do
      definitions = parse_fixture("simple_unique.dmn")

      {:error, :missing_required_input, _metadata} =
        Evaluator.evaluate(definitions, nil, %{})

      {_start_measurements, _start_metadata} =
        await_telemetry_event(:start, &(not Map.has_key?(&1, :hit_policy)))

      {stop_measurements, stop_metadata} =
        await_telemetry_event(:stop, &(not Map.has_key?(&1, :hit_policy)))

      assert is_integer(stop_measurements.duration)
      assert stop_metadata.decision_model_id == nil
      refute Map.has_key?(stop_metadata, :hit_policy)
    end

    test "duration measurement is always positive" do
      definitions = parse_fixture("simple_unique.dmn")
      {:ok, _result} = Evaluator.evaluate(definitions, nil, %{"age" => 25})

      {stop_measurements, _metadata} =
        await_telemetry_event(:stop, &(&1[:hit_policy] == :unique))

      assert stop_measurements.duration > 0
    end

    test "failed evaluation emits :stop event with error-only metadata (no exception)" do
      definitions = parse_fixture("all_hit_policies.dmn")

      {:error, :ambiguous_decision, _} =
        Evaluator.evaluate(definitions, nil, %{"value" => 5})

      {_start_measurements, _start_metadata} =
        await_telemetry_event(:start, fn _ -> true end)

      {stop_measurements, stop_metadata} =
        await_telemetry_event(:stop, &(not Map.has_key?(&1, :hit_policy)))

      assert is_integer(stop_measurements.duration)
      assert stop_metadata.decision_model_id == nil
      refute Map.has_key?(stop_metadata, :hit_policy)
      refute Map.has_key?(stop_metadata, :matched_rule_count)
    end

    test "decision_not_found error produces :stop with the queried decision_model_id" do
      definitions = parse_fixture("simple_unique.dmn")

      {:error, :decision_not_found, %{decision_id: "nonexistent"}} =
        Evaluator.evaluate(definitions, "nonexistent", %{"age" => 25})

      {_start_measurements, start_metadata} =
        await_telemetry_event(:start, &(&1[:decision_model_id] == "nonexistent"))

      assert start_metadata.decision_model_id == "nonexistent"

      {stop_measurements, stop_metadata} =
        await_telemetry_event(:stop, &(&1[:decision_model_id] == "nonexistent"))

      assert is_integer(stop_measurements.duration)
      assert stop_metadata.decision_model_id == "nonexistent"
    end
  end

  describe "evaluate_service/4 telemetry" do
    test "successful service evaluation emits :start then :stop with service_id" do
      xml = read_fixture("decision_service_basic.dmn")
      {:ok, definitions} = DMN.parse_and_validate(xml)

      {:ok, _result} =
        Evaluator.evaluate_service(definitions, "DS_eligibility", %{"Age" => 30, "Income" => 50_000})

      {_start_measurements, start_metadata} =
        await_telemetry_event(:start, &(Map.get(&1, :service_id) == "DS_eligibility"))

      assert start_metadata.decision_model_id == nil

      {_stop_measurements, stop_metadata} =
        await_telemetry_event(:stop, &(Map.get(&1, :service_id) == "DS_eligibility"))

      assert stop_metadata.output_decision_count == 1
    end
  end
end

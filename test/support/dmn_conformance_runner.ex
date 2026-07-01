defmodule EvilEngine.Test.DmnConformanceRunner do
  @moduledoc """
  YAML-driven DMN conformance test runner.

  Reads DMN specs from `test/conformance/` (`type: dmn`), deploys fixture
  DMN files via HTTP, evaluates decisions or decision services, and
  asserts against each spec's `expected` block.

  ## Supported spec shapes

  - **Single evaluate** — `evaluate` + `expected`
  - **Deploy-only error** — `expected.deploy_status` / `expected.deploy_error` (no evaluate)
  - **Decision service** — `evaluate_service` + `expected`
  - **Multi-evaluate** — `evaluate_<suffix>` + `expected_<suffix>` pairs (e.g. C55, C57)

  ## Fixture keys

  - `fixture` — single `.dmn` file name
  - `fixtures` — ordered list of `.dmn` files (cross-model import)
  - `fixture_multi` — alias for ordered multi-deploy (imported BKM consumer)

  Set `fixture: null` to skip deploy (evaluate-only specs such as C43).

  ## Not yet expressible in YAML

  - Trace sub-assertions (`bkmTraces`, `importTraces` non-empty) — hand-coded in
    the legacy suite for C46/C48; add `expected.trace_bkm_traces_nonempty` etc.
    when needed.
  - Extra variants without YAML files (C58b/C58c default-output multi-output,
    C59b inputValues accept path).
  """

  @conformance_dir Path.expand("../conformance", __DIR__)

  @doc """
  Load and parse a DMN YAML spec file from `test/conformance/`.
  """
  def load_spec(yaml_filename) do
    path = Path.join(@conformance_dir, yaml_filename)
    YamlElixir.read_from_file!(path)
  end

  @doc """
  List DMN YAML spec files (`type: dmn`) in `test/conformance/`.
  """
  def list_specs do
    @conformance_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".yaml"))
    |> Enum.sort()
    |> Enum.filter(fn yaml_filename ->
      load_spec(yaml_filename)["type"] == "dmn"
    end)
  end

  @doc """
  Run a full DMN conformance spec: deploy fixtures (when present), evaluate,
  and assert all declared expectations.
  """
  def run_auto(spec) do
    deploy_result = deploy_all_fixtures(spec)

    if deploy_only_spec?(spec) do
      assert_deploy_expectations(deploy_result, spec["expected"])
    else
      prime_decision_cache_if_needed(spec)
      run_all_evaluations(spec)
    end

    :ok
  end

  defp deploy_only_spec?(spec) do
    spec["expected"]["deploy_status"] != nil or spec["expected"]["deploy_error"] != nil
  end

  defp deploy_all_fixtures(%{"fixture" => nil}), do: {nil, nil}

  defp deploy_all_fixtures(spec) do
    fixture_names = resolve_fixture_names(spec)
    allowed_statuses = allowed_deploy_statuses(spec)

    Enum.reduce(fixture_names, {nil, nil}, fn fixture_name, _acc ->
      {status, body} = apply(EvilEngine.ExecutionCase, :http_deploy_dmn, [fixture_name])
      assert_deploy_status!(status, body, fixture_name, allowed_statuses)
      {status, body}
    end)
  end

  defp allowed_deploy_statuses(%{"expected" => %{"deploy_status" => deploy_statuses}})
       when is_list(deploy_statuses),
       do: deploy_statuses

  defp allowed_deploy_statuses(_spec), do: [201, 409]

  defp assert_deploy_status!(status, body, fixture_name, allowed_statuses) do
    if status in allowed_statuses do
      :ok
    else
      raise ExUnit.AssertionError,
        message:
          "Expected deploy status in #{inspect(allowed_statuses)} for '#{fixture_name}', " <>
            "got #{status}: #{inspect(body)}"
    end
  end

  defp prime_decision_cache_if_needed(spec) do
    if spec["decision_definition_id"] && not evaluate_not_found_spec?(spec) do
      ensure_decision_cached(spec["decision_definition_id"])
    end
  end

  defp evaluate_not_found_spec?(spec) do
    spec
    |> all_expected_blocks()
    |> Enum.any?(fn expected_config ->
      expected_config["status"] == 404 &&
        expected_config["error"] == "decision_definition_not_found"
    end)
  end

  defp all_expected_blocks(spec) do
    base_expected =
      if spec["expected"], do: [spec["expected"]], else: []

    suffix_expected =
      spec
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "expected_"))
      |> Enum.map(&Map.fetch!(spec, &1))

    base_expected ++ suffix_expected
  end

  defp ensure_decision_cached(decision_definition_id) do
    resolver = EvilEngine.Execution.DecisionResolver.adapter()

    with {:ok, resolved} <- resolver.resolve_latest_version(decision_definition_id),
         {:ok, definitions} <- EvilEngine.DMN.parse_and_validate(resolved.dmn_xml) do
      EvilEngine.DMN.ModelCache.put_new(resolved.decision_version_id, definitions)
      :ok
    else
      error ->
        raise ExUnit.AssertionError,
          message:
            "Failed to prime DMN cache for '#{decision_definition_id}': #{inspect(error)}"
    end
  end

  defp resolve_fixture_names(spec) do
    cond do
      is_list(spec["fixture_multi"]) -> spec["fixture_multi"]
      is_list(spec["fixtures"]) -> spec["fixtures"]
      is_binary(spec["fixture"]) -> [spec["fixture"]]
      true -> []
    end
  end

  defp run_all_evaluations(spec) do
    decision_definition_id = spec["decision_definition_id"]

    Enum.each(evaluation_pairs(spec), fn {evaluate_key, expected_key} ->
      evaluate_config = spec[evaluate_key]
      expected_config = spec[expected_key]

      if evaluate_config["service_id"] do
        run_decision_service_evaluation(decision_definition_id, evaluate_config, expected_config)
      else
        run_decision_evaluation(decision_definition_id, evaluate_config, expected_config)
      end
    end)
  end

  defp evaluation_pairs(spec) do
    multi_evaluate_keys =
      spec
      |> Map.keys()
      |> Enum.filter(fn key -> String.starts_with?(key, "evaluate_") end)
      |> Enum.sort()

    case multi_evaluate_keys do
      [] ->
        if spec["evaluate_service"] do
          [{"evaluate_service", "expected"}]
        else
          [{"evaluate", "expected"}]
        end

      keys ->
        Enum.map(keys, fn evaluate_key ->
          suffix = String.replace_prefix(evaluate_key, "evaluate_", "")
          {evaluate_key, "expected_" <> suffix}
        end)
    end
  end

  defp run_decision_evaluation(decision_definition_id, evaluate_config, expected_config) do
    input = evaluate_config["input"] || %{}
    decision_model_id = evaluate_config["decision_model_id"]

    evaluate_opts =
      if decision_model_id do
        [decision_model_id: decision_model_id]
      else
        []
      end

    {status, body} =
      apply(EvilEngine.ExecutionCase, :http_evaluate_decision, [
        decision_definition_id,
        input,
        evaluate_opts
      ])

    assert_evaluation_expectations(status, body, expected_config)
  end

  defp run_decision_service_evaluation(decision_definition_id, evaluate_config, expected_config) do
    service_id = evaluate_config["service_id"]
    input = evaluate_config["input"] || %{}

    {status, body} =
      apply(EvilEngine.ExecutionCase, :http_evaluate_decision_service, [
        decision_definition_id,
        service_id,
        input
      ])

    assert_service_expectations(status, body, expected_config)
  end

  defp assert_deploy_expectations({status, body}, expected_config) do
    assert_status_in(status, expected_config["deploy_status"],
      label: "deploy status",
      body: body
    )

    if expected_error = expected_config["deploy_error"] do
      assert_error_in(body, expected_error, label: "deploy error")
    end
  end

  defp assert_evaluation_expectations(status, body, expected_config) do
    assert_status(status, expected_config["status"], body)

    if expected_error = expected_config["error"] do
      assert_error_equals(body, expected_error)
    end

    if expected_hit_policy = expected_config["hit_policy"] do
      assert_field_equals(body, "hitPolicy", expected_hit_policy, "hit policy")
    end

    if expected_decision_model_id = expected_config["decision_model_id"] do
      assert_field_equals(body, "decisionModelId", expected_decision_model_id, "decision model id")
    end

    if expected_trace_count = expected_config["trace_decision_count"] do
      actual_count = get_in(body, ["trace", "decisions"]) |> List.wrap() |> length()

      unless actual_count == expected_trace_count do
        raise ExUnit.AssertionError,
          message:
            "Expected trace decision count #{expected_trace_count}, got #{actual_count}"
      end
    end

    assert_result_expectations(body, expected_config)
  end

  defp assert_service_expectations(status, body, expected_config) do
    assert_status(status, expected_config["status"], body)

    if expected_error = expected_config["error"] do
      assert_error_equals(body, expected_error)
    end

    if expected_service_id = expected_config["service_id"] do
      assert_field_equals(body, "serviceId", expected_service_id, "service id")
    end

    if expected_outputs = expected_config["outputs"] do
      actual_outputs = body["outputs"] || %{}

      Enum.each(expected_outputs, fn {key, expected_value} ->
        actual_value = Map.get(actual_outputs, key)

        unless values_match?(actual_value, expected_value) do
          raise ExUnit.AssertionError,
            message:
              "Expected service output '#{key}' to be #{inspect(expected_value)}, " <>
                "got #{inspect(actual_value)} in #{inspect(actual_outputs)}"
        end
      end)
    end
  end

  defp assert_result_expectations(body, expected_config) do
    result = body["result"]

    cond do
      expected_config["result"] != nil ->
        unless values_match?(result, expected_config["result"]) do
          raise ExUnit.AssertionError,
            message:
              "Expected result #{inspect(expected_config["result"])}, " <>
                "got #{inspect(result)}"
        end

      expected_config["result_value"] != nil ->
        expected_value = expected_config["result_value"]

        actual_value =
          case expected_config["result_key"] do
            nil -> result
            result_key when is_binary(result_key) -> get_in(result, String.split(result_key, "."))
          end

        unless values_match?(actual_value, expected_value) do
          raise ExUnit.AssertionError,
            message:
              "Expected result value #{inspect(expected_value)}, got #{inspect(actual_value)}"
        end

      true ->
        :ok
    end
  end

  defp assert_status(actual_status, expected_status, body) when is_integer(expected_status) do
    unless actual_status == expected_status do
      raise ExUnit.AssertionError,
        message:
          "Expected HTTP status #{expected_status}, got #{actual_status}: #{inspect(body)}"
    end
  end

  defp assert_status(actual_status, nil, _body), do: actual_status

  defp assert_status_in(actual_status, expected_statuses, opts) do
    label = Keyword.get(opts, :label, "status")
    body = Keyword.get(opts, :body)

    unless actual_status in expected_statuses do
      raise ExUnit.AssertionError,
        message:
          "Expected #{label} in #{inspect(expected_statuses)}, " <>
            "got #{actual_status}: #{inspect(body)}"
    end
  end

  defp assert_error_equals(body, expected_error) do
    actual_error = body["error"]

    unless actual_error == expected_error do
      raise ExUnit.AssertionError,
        message: "Expected error '#{expected_error}', got '#{actual_error}'"
    end
  end

  defp assert_error_in(body, expected_errors, opts) when is_list(expected_errors) do
    label = Keyword.get(opts, :label, "error")
    actual_error = body["error"]

    unless actual_error in expected_errors do
      raise ExUnit.AssertionError,
        message:
          "Expected #{label} in #{inspect(expected_errors)}, got '#{actual_error}'"
    end
  end

  defp assert_field_equals(body, field_name, expected_value, label) do
    actual_value = Map.get(body, field_name)

    unless actual_value == expected_value do
      raise ExUnit.AssertionError,
        message:
          "Expected #{label} '#{expected_value}', got '#{actual_value}'"
    end
  end

  defp values_match?(actual_value, expected_value)
       when is_number(actual_value) and is_number(expected_value) do
    abs(actual_value - expected_value) < 0.001
  end

  defp values_match?(actual_value, expected_value)
       when is_map(actual_value) and is_map(expected_value) do
    Enum.all?(expected_value, fn {key, nested_expected} ->
      nested_actual = Map.get(actual_value, key)
      values_match?(nested_actual, nested_expected)
    end)
  end

  defp values_match?(actual_value, expected_value)
       when is_list(actual_value) and is_list(expected_value) do
    length(actual_value) == length(expected_value) and
      Enum.zip(actual_value, expected_value)
      |> Enum.all?(fn {actual_element, expected_element} ->
        values_match?(actual_element, expected_element)
      end)
  end

  defp values_match?(actual_value, expected_value), do: actual_value == expected_value
end

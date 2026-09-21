defmodule BfwEngine.Test.ConformanceRunner do
  @moduledoc """
  YAML-driven conformance test runner.

  Reads a YAML spec file, deploys the BPMN fixture via HTTP,
  starts a PI, and asserts final state and finalTokens against
  the spec's `expected` block.

  ## Auto tier

  For specs with no interactive steps, the runner handles
  everything: deploy → start → wait → assert.

  ## Interactive tier

  For specs requiring mid-execution steps (user task finish, async
  completion, etc.), the caller invokes `deploy_and_start/1` and
  `assert_expectations/2` separately, performing interaction steps
  in between.
  """

  require Ash.Query

  alias BfwEngine.Persistence.Api, as: Domain
  alias BfwEngine.Persistence.Resources.ProcessInstance, as: PiResource

  @conformance_dir Path.expand("../conformance", __DIR__)
  @terminal_process_instance_states ["finished", "fatal", "aborted", "escalated", "cancelled", "compensated"]

  @doc """
  Load and parse a YAML spec file from `test/conformance/`.
  """
  def load_spec(yaml_filename) do
    path = Path.join(@conformance_dir, yaml_filename)
    YamlElixir.read_from_file!(path)
  end

  @doc """
  List all `.yaml` spec files in `test/conformance/`.
  """
  def list_specs do
    @conformance_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".yaml"))
    |> Enum.sort()
  end

  @doc """
  Run a full auto-tier conformance test: deploy, start, wait, assert.

  Uses `ExecutionCase` helper functions directly (they are public
  in the module and can be called as `BfwEngine.ExecutionCase.fn()`).
  """
  def run_auto(spec) do
    process_instance_id = deploy_and_start(spec)
    wait_for_completion(process_instance_id, spec)
    assert_expectations(process_instance_id, spec)
    process_instance_id
  end

  @doc """
  Deploy the BPMN fixture and start a PI. Returns the PI ID.

  Supports two start modes via the `start.mode` YAML key:

  - `"http"` (default): Start via HTTP POST to the start endpoint.
  - `"timer_auto"`: Deploy only, then poll the DB until the Scheduler
    auto-creates a PI from a Timer Start Event.

  Supports an optional `child_fixtures` YAML key (list of BPMN filenames) for
  scenarios that call sub-processes or call activities in separate BPMN files.
  Child fixtures are deployed in the order listed before the main `fixture`,
  so calledElement references resolve correctly (deepest dependency first).
  """
  def deploy_and_start(spec) do
    fixture = spec["fixture"]
    start_config = spec["start"] || %{}

    deploy_dmn_fixtures(spec["dmn_fixtures"] || [])
    deploy_child_fixtures(spec["child_fixtures"] || [])

    {201, _} = apply(BfwEngine.ExecutionCase, :http_deploy, [fixture])

    case start_config["mode"] do
      "timer_auto" -> poll_for_timer_started_pi(spec["process_model_id"])
      _ -> start_via_http(spec["process_model_id"], start_config)
    end
  end

  defp start_via_http(process_model_id, start_config) do
    payload = start_config["payload"]

    body =
      if payload do
        %{"payload" => payload}
      else
        %{}
      end

    body =
      case start_config["start_event_id"] do
        nil -> body
        id -> Map.put(body, "startEventId", id)
      end

    {201, response} = apply(BfwEngine.ExecutionCase, :http_start, [process_model_id, body])
    response["processInstanceId"]
  end

  defp poll_for_timer_started_pi(process_model_id) do
    version_id = resolve_version_id(process_model_id)
    poll_for_timer_started_pi(version_id, 40, 50)
  end

  defp poll_for_timer_started_pi(version_id, 0, _interval_ms) do
    raise RuntimeError,
          "No PI created by timer for version '#{version_id}' within timeout"
  end

  defp poll_for_timer_started_pi(version_id, remaining_attempts, interval_ms) do
    case find_pi_for_version(version_id) do
      nil ->
        Process.sleep(interval_ms)
        poll_for_timer_started_pi(version_id, remaining_attempts - 1, interval_ms)

      process_instance_id ->
        process_instance_id
    end
  end

  defp resolve_version_id(process_model_id) do
    alias BfwEngine.Persistence.Resources.Process, as: ProcessResource
    alias BfwEngine.Persistence.Resources.ProcessVersion, as: PvResource

    process =
      ProcessResource
      |> Ash.Query.filter(process_model_id == ^process_model_id)
      |> Ash.read_one!(domain: Domain, authorize?: false)

    unless process do
      raise RuntimeError, "No process found for model_id '#{process_model_id}'"
    end

    PvResource
    |> Ash.Query.filter(process_id == ^process.id)
    |> Ash.Query.sort(deployed_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(domain: Domain, authorize?: false)
    |> case do
      [version] -> version.id
      [] -> raise RuntimeError, "No version found for process '#{process_model_id}'"
    end
  end

  defp find_pi_for_version(version_id) do
    PiResource
    |> Ash.Query.filter(process_version_id == ^version_id)
    |> Ash.Query.limit(1)
    |> Ash.read!(domain: Domain, authorize?: false)
    |> case do
      [process_instance] -> process_instance.id
      [] -> nil
    end
  end

  @doc """
  Wait for the PI to reach the expected final state.

  Uses DB polling via `ProcessInteractions.await_process_instance_state`
  rather than PID monitoring to avoid Ecto Sandbox ownership issues when
  terminate end events kill handler tasks mid-transaction.
  """
  def wait_for_completion(process_instance_id, spec) do
    expected = spec["expected"]
    final_state = expected["final_state"]
    timeout_milliseconds =
      case spec["wait_timeout_ms"] do
        timeout when is_integer(timeout) and timeout > 0 -> timeout
        _other -> 20_000
      end

    if final_state in @terminal_process_instance_states do
      case apply(BfwEngine.Test.ProcessInteractions, :await_process_instance_state, [
             process_instance_id,
             final_state,
             [timeout: timeout_milliseconds]
           ]) do
        {:ok, _process_instance} -> :ok
        {:error, :timeout} -> raise "PI #{process_instance_id} did not reach '#{final_state}' within #{timeout_milliseconds}ms"
      end
    else
      Process.sleep(200)
    end
  end

  @doc """
  Assert all expectations defined in the spec's `expected` block.
  """
  def assert_expectations(process_instance_id, spec) do
    expected = spec["expected"]
    expected_final_state = expected["final_state"]

    assert_final_state(process_instance_id, expected_final_state)

    if expected_final_state in @terminal_process_instance_states do
      apply(BfwEngine.Test.DbAssertions, :assert_all_fnis_terminal!, [process_instance_id])
    end

    if expected_final_state == "finished" do
      assert_final_tokens_not_nil(process_instance_id)
    end

    if expected["final_tokens"] do
      assert_final_tokens(process_instance_id, expected["final_tokens"])
    end

    if expected["fni_count"] do
      flow_node_instances =
        apply(BfwEngine.Test.DbAssertions, :fetch_flow_node_instances, [process_instance_id])
      assert_flow_node_instance_count(flow_node_instances, expected["fni_count"])
    end
  end

  defp assert_final_state(process_instance_id, expected_state) do
    apply(BfwEngine.Test.DbAssertions, :assert_pi_state!, [process_instance_id, expected_state])
  end

  defp assert_final_tokens_not_nil(process_instance_id) do
    process_instance = load_process_instance_with_final_tokens(process_instance_id)

    if process_instance.final_tokens == nil do
      raise ExUnit.AssertionError,
        message:
          "Expected non-nil finalTokens for finished PI #{process_instance_id}, got nil"
    end
  end

  defp assert_final_tokens(process_instance_id, expected_tokens) do
    process_instance = load_process_instance_with_final_tokens(process_instance_id)

    if expected_tokens == nil do
      unless process_instance.final_tokens == nil do
        raise ExUnit.AssertionError,
          message: "Expected nil finalTokens, got #{inspect(process_instance.final_tokens)}"
      end
    else
      unless is_list(process_instance.final_tokens) do
        raise ExUnit.AssertionError,
          message: "Expected list finalTokens, got #{inspect(process_instance.final_tokens)}"
      end

      unless length(process_instance.final_tokens) == length(expected_tokens) do
        raise ExUnit.AssertionError,
          message:
            "Expected #{length(expected_tokens)} final tokens, got #{length(process_instance.final_tokens)}"
      end

      Enum.each(expected_tokens, fn expected_token ->
        actual_token =
          Enum.find(process_instance.final_tokens, fn actual ->
            actual["endEventId"] == expected_token["endEventId"]
          end)

        unless actual_token do
          raise ExUnit.AssertionError,
            message:
              "No finalToken with endEventId '#{expected_token["endEventId"]}' found in #{inspect(process_instance.final_tokens)}"
        end

        if expected_payload = expected_token["payload"] do
          assert_token_payload_contains(
            actual_token["payload"],
            expected_payload,
            expected_token["endEventId"]
          )
        end
      end)
    end
  end

  defp load_process_instance_with_final_tokens(process_instance_id) do
    PiResource
    |> Ash.Query.filter(id == ^process_instance_id)
    |> Ash.Query.load(:final_tokens)
    |> Ash.read_one!(domain: Domain, authorize?: false)
  end

  defp assert_token_payload_contains(actual_payload, expected_payload, end_event_id) do
    unless is_map(actual_payload) do
      raise ExUnit.AssertionError,
        message:
          "Expected finalToken payload for endEventId '#{end_event_id}' to be a map, " <>
            "got #{inspect(actual_payload)}"
    end

    Enum.each(expected_payload, fn {key, expected_value} ->
      actual_value = Map.get(actual_payload, key)

      unless payload_values_match?(actual_value, expected_value) do
        raise ExUnit.AssertionError,
          message:
            "finalToken payload for endEventId '#{end_event_id}' key '#{key}': " <>
              "expected #{inspect(expected_value)}, got #{inspect(actual_value)} " <>
              "in #{inspect(actual_payload)}"
      end
    end)
  end

  defp payload_values_match?(actual_value, expected_value)
       when is_map(actual_value) and is_map(expected_value) do
    Enum.all?(expected_value, fn {key, nested_expected} ->
      nested_actual = Map.get(actual_value, key)
      payload_values_match?(nested_actual, nested_expected)
    end)
  end

  defp payload_values_match?(actual_value, expected_value), do: actual_value == expected_value

  defp assert_flow_node_instance_count(flow_node_instances, expected_count) do
    unless length(flow_node_instances) == expected_count do
      raise ExUnit.AssertionError,
        message: "Expected #{expected_count} FNIs, got #{length(flow_node_instances)}"
    end
  end

  defp deploy_dmn_fixtures(dmn_fixture_names) do
    Enum.each(dmn_fixture_names, fn dmn_fixture ->
      {201, _} = apply(BfwEngine.ExecutionCase, :http_deploy_dmn, [dmn_fixture])
    end)
  end

  defp deploy_child_fixtures(child_fixture_names) do
    Enum.each(child_fixture_names, fn child_fixture ->
      {201, _} = apply(BfwEngine.ExecutionCase, :http_deploy, [child_fixture])
    end)
  end
end

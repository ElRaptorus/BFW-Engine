defmodule EvilEngine.Integration.Deployment.ErrorHumanizationDeployTest do
  @moduledoc """
  Integration tests for humanized deploy error responses.

  Verifies that invalid BPMN deploy failures return HTTP 400 with
  human-readable details and no `inspect/1` leakage in the response body.
  """
  use EvilEngine.ExecutionCase, async: false

  describe "POST /processes — invalid BPMN XML" do
    test "returns 400 with human-readable parse error and no inspect leakage" do
      invalid_xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_Broken">
        <bpmn:process id="BrokenProcess" isExecutable="true">
          <bpmn:extensionElements>
            <evil:version>1.0.0</evil:version>
          </bpmn:extensionElements>
          <bpmn:startEvent id="Start_1" />
      """

      {400, body} = http_deploy_xml(invalid_xml)

      assert body["error"] == "parse_error"
      assert body["message"] =~ "parsing failed"

      failures = body["failures"]
      assert is_list(failures)
      assert failures != []

      details =
        failures
        |> Enum.flat_map(& &1["details"])
        |> Enum.join(" ")

      assert details =~ "Invalid XML syntax" or details =~ "XML"
      refute_response_leaks_inspect(body)
    end
  end

  describe "POST /processes — invalid BPMN validation" do
    test "returns 422 with human-readable validation failures and no inspect leakage" do
      missing_version_xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                        xmlns:evil="https://evilengine.dev/schema/bpmn"
                        id="Definitions_NoVersion">
        <bpmn:process id="NoVersionProcess" isExecutable="true">
          <bpmn:startEvent id="Start_1" />
          <bpmn:endEvent id="End_1" />
          <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="End_1" />
        </bpmn:process>
      </bpmn:definitions>
      """

      {422, body} = http_deploy_xml(missing_version_xml)

      assert body["error"] == "validation_failed"
      assert body["message"] =~ "validation failed"

      failures = body["failures"]
      assert is_list(failures)
      assert failures != []

      details =
        failures
        |> Enum.flat_map(& &1["details"])
        |> Enum.join(" ")

      assert details =~ "version" or details =~ "missing required"
      refute_response_leaks_inspect(body)
    end
  end

  defp refute_response_leaks_inspect(body) do
    encoded = Jason.encode!(body)

    refute encoded =~ "%{", "response must not contain inspect map syntax"
    refute encoded =~ "#PID", "response must not contain PID inspect syntax"
    refute encoded =~ "FunctionClauseError", "response must not expose internal exception names"
    refute encoded =~ ":error", "response must not contain raw Elixir tuple atoms"
  end
end

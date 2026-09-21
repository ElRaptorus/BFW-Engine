defmodule BfwEngine.Integration.DMN.DmnEvaluateEnrichmentTest do
  @moduledoc """
  Integration test verifying enrichment fields on the REST evaluate
  response: definitionsId, definitionsNamespace, decisionVersionId,
  and trace.inputCoercions (7H.3).
  """
  use BfwEngine.ExecutionCase, async: false

  @moduletag :integration

  describe "POST /decisions/{id}/evaluate enriched response" do
    test "response contains definitionsId and definitionsNamespace" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")

      {200, body} = http_evaluate_decision("definitions_discount", %{"age" => 25})

      assert body["definitionsId"] == "definitions_discount"
      assert body["definitionsNamespace"] == "https://example.com/dmn/discount"
    end

    test "response contains decisionVersionId when model is deployed" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")

      {200, body} = http_evaluate_decision("definitions_discount", %{"age" => 25})

      assert is_binary(body["decisionVersionId"]),
             "Expected non-nil decisionVersionId, got: #{inspect(body["decisionVersionId"])}"
    end

    test "trace includes inputCoercions list" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")

      {200, body} = http_evaluate_decision("definitions_discount", %{"age" => 25})

      trace = body["trace"]
      assert is_map(trace)
      assert is_list(trace["inputCoercions"])
      assert is_list(trace["decisions"])
      assert trace["decisions"] != []
    end

    test "trace includes bkmTraces and importTraces on decisions" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")

      {200, body} = http_evaluate_decision("definitions_discount", %{"age" => 25})

      [decision | _] = body["trace"]["decisions"]
      assert decision["bkmTraces"] == []
      assert decision["importTraces"] == []
      assert is_binary(decision["decisionModelId"])
      assert is_binary(decision["decisionName"])
      assert is_integer(decision["durationMicroseconds"])
      assert decision["durationMicroseconds"] >= 0
    end
  end
end

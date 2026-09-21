defmodule BfwEngine.Integration.DMN.DmnCl3IntegrationTest do
  @moduledoc """
  Full-stack integration tests for DMN CL3 features.

  Exercises Decision Service evaluation and boxed context expressions through
  the HTTP pipeline: deploy via `POST /decisions`, evaluate via service and
  ad-hoc endpoints.
  """
  use BfwEngine.ExecutionCase, async: false

  @moduletag :integration

  @definitions_decision_service_basic "Definitions_ds_basic"
  @definitions_boxed_context "definitions_context"
  @service_eligibility "DS_eligibility"

  describe "Decision Service evaluation via REST" do
    test "deploys decision_service_basic and evaluates DS_eligibility" do
      {201, _} = http_deploy_dmn("decision_service_basic.dmn")

      {200, body} =
        http_evaluate_decision_service(
          @definitions_decision_service_basic,
          @service_eligibility,
          %{"Age" => 30, "Income" => 50_000}
        )

      assert body["serviceId"] == @service_eligibility
      assert body["serviceName"] == "Eligibility Service"
      assert body["outputs"]["Eligibility"] == "approved"
      assert is_map(body["trace"])
      assert is_binary(body["evaluatedAt"])
      assert is_integer(body["durationMicroseconds"])
    end

    test "404 when evaluating a non-existent decision service" do
      {201, _} = http_deploy_dmn("decision_service_basic.dmn")

      {404, body} =
        http_evaluate_decision_service(
          @definitions_decision_service_basic,
          "DS_nonexistent",
          %{"Age" => 30, "Income" => 50_000}
        )

      assert body["error"] == "service_not_found"
    end

    test "404 when evaluating a service on a non-existent model" do
      {404, body} =
        http_evaluate_decision_service(
          "nonexistent_decision_#{System.unique_integer([:positive])}",
          @service_eligibility,
          %{"Age" => 30, "Income" => 50_000}
        )

      assert body["error"] == "decision_definition_not_found"
    end
  end

  describe "nested Decision Service evaluation via REST (P4.4)" do
    test "deploys decision_service_nested and evaluates DS_fee_calculation" do
      {201, _} = http_deploy_dmn("decision_service_nested.dmn")

      {200, body} =
        http_evaluate_decision_service(
          "Definitions_ds_nested",
          "DS_fee_calculation",
          %{"Amount" => 15_000, "Category" => "premium"}
        )

      assert body["serviceId"] == "DS_fee_calculation"
      assert body["serviceName"] == "Fee Calculation Service"
      # Amount=15000, Category=premium → BaseRate=0.05, AdjustedRate=0.05*0.9=0.045 (>10000), Fee=15000*0.045=675
      assert body["outputs"]["Fee"] == 15_000 * 0.05 * 0.9
      assert is_map(body["trace"])
      assert is_list(body["trace"]["decisions"])
      assert length(body["trace"]["decisions"]) >= 3
    end

    test "evaluates DS_with_input_decisions where base rate is an input decision" do
      {201, _} = http_deploy_dmn("decision_service_nested.dmn")

      {200, body} =
        http_evaluate_decision_service(
          "Definitions_ds_nested",
          "DS_with_input_decisions",
          %{"Amount" => 5_000, "Category" => "standard"}
        )

      assert body["outputs"]["Fee"] == 5_000 * 0.10
    end

    test "nested service returns trace for all evaluated decisions" do
      {201, _} = http_deploy_dmn("decision_service_nested.dmn")

      {200, body} =
        http_evaluate_decision_service(
          "Definitions_ds_nested",
          "DS_fee_calculation",
          %{"Amount" => 500, "Category" => "standard"}
        )

      decision_ids =
        Enum.map(body["trace"]["decisions"], & &1["decisionModelId"])

      assert "Decision_base_rate" in decision_ids
      assert "Decision_adjusted_rate" in decision_ids
      assert "Decision_fee" in decision_ids
    end
  end

  describe "boxed context evaluation via REST" do
    test "deploys boxed_context_basic and evaluates Decision_context" do
      {201, _} = http_deploy_dmn("boxed_context_basic.dmn")

      {200, body} =
        http_evaluate_decision(
          @definitions_boxed_context,
          %{},
          decision_model_id: "Decision_context"
        )

      assert body["hitPolicy"] == "boxed_expression"
      assert body["result"] == 11
      assert body["decisionModelId"] == "Decision_context"
    end
  end
end

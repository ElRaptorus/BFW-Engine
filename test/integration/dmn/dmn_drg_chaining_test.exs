defmodule EvilEngine.Integration.DMN.DmnDrgChainingTest do
  @moduledoc """
  Full-stack integration tests for DMN Phase 4: DRD chaining, BKM invocation,
  and cross-model import resolution.

  Exercises the HTTP pipeline end-to-end through `POST /decisions` (deploy)
  and `POST /decisions/{model_id}/evaluate` for multi-decision models,
  BKM-backed decisions, and import resolution.
  """
  use EvilEngine.ExecutionCase, async: false

  @moduletag :integration

  # ---------------------------------------------------------------------------
  # DRD Chaining — linear, diamond, three-level
  # ---------------------------------------------------------------------------

  describe "DRD linear chain" do
    setup do
      {201, _} = http_deploy_dmn("drg_linear_chain.dmn")
      :ok
    end

    test "evaluates target decision through upstream dependency" do
      {200, body} =
        http_evaluate_decision("definitions_linear_chain", %{"x" => 5},
          decision_model_id: "Decision_A"
        )

      assert body["result"] == 30
    end

    test "trace contains both decisions in dependency order" do
      {200, body} =
        http_evaluate_decision("definitions_linear_chain", %{"x" => 5},
          decision_model_id: "Decision_A"
        )

      decision_ids = Enum.map(body["trace"]["decisions"], & &1["decisionModelId"])
      assert decision_ids == ["Decision_B", "Decision_A"]
    end
  end

  describe "DRD diamond" do
    setup do
      {201, _} = http_deploy_dmn("drg_diamond.dmn")
      :ok
    end

    test "evaluates diamond with shared dependency evaluated once" do
      {200, body} =
        http_evaluate_decision("definitions_diamond", %{"x" => 1},
          decision_model_id: "Decision_A"
        )

      assert body["result"] == 34
    end

    test "trace contains four decisions" do
      {200, body} =
        http_evaluate_decision("definitions_diamond", %{"x" => 1},
          decision_model_id: "Decision_A"
        )

      trace_decisions = body["trace"]["decisions"]
      assert length(trace_decisions) == 4

      decision_ids = Enum.map(trace_decisions, & &1["decisionModelId"])
      assert "Decision_D" in decision_ids
      assert "Decision_B" in decision_ids
      assert "Decision_C" in decision_ids
      assert "Decision_A" in decision_ids

      d_index = Enum.find_index(decision_ids, &(&1 == "Decision_D"))
      a_index = Enum.find_index(decision_ids, &(&1 == "Decision_A"))
      assert d_index < a_index
    end
  end

  describe "DRD three-level chain" do
    setup do
      {201, _} = http_deploy_dmn("drg_three_level.dmn")
      :ok
    end

    test "evaluates three-level transitive chain" do
      {200, body} =
        http_evaluate_decision("definitions_three_level", %{"x" => 0},
          decision_model_id: "Decision_A"
        )

      assert body["result"] == 4
    end

    test "trace contains all four decisions in order" do
      {200, body} =
        http_evaluate_decision("definitions_three_level", %{"x" => 0},
          decision_model_id: "Decision_A"
        )

      decision_ids = Enum.map(body["trace"]["decisions"], & &1["decisionModelId"])
      assert length(decision_ids) == 4
      assert List.first(decision_ids) == "Decision_D"
      assert List.last(decision_ids) == "Decision_A"
    end
  end

  # ---------------------------------------------------------------------------
  # DRG cycle detection (deploy-time rejection)
  # ---------------------------------------------------------------------------

  describe "DRG cycle detection" do
    test "deploying a model with a decision cycle returns validation error" do
      {status, body} = http_deploy_dmn("drg_cycle.dmn")
      assert status in [400, 422]
      assert body["error"] in ["validation_failed", "dmn_parse_error"]
    end
  end

  # ---------------------------------------------------------------------------
  # BKM invocation — decision table and literal expression bodies
  # ---------------------------------------------------------------------------

  describe "BKM invocation with decision table body" do
    setup do
      {201, _} = http_deploy_dmn("bkm_invocation_table.dmn")
      :ok
    end

    test "evaluates decision that invokes BKM with table body" do
      {200, body} =
        http_evaluate_decision("definitions_bkm_invoke_dt", %{"customerAge" => 70},
          decision_model_id: "Decision_discount"
        )

      assert body["result"] == 40
    end

    test "BKM table FIRST hit policy selects correct rule" do
      {200, body} =
        http_evaluate_decision("definitions_bkm_invoke_dt", %{"customerAge" => 25},
          decision_model_id: "Decision_discount"
        )

      assert body["result"] == 10
    end
  end

  describe "BKM invocation with literal expression body" do
    setup do
      {201, _} = http_deploy_dmn("bkm_invocation_literal.dmn")
      :ok
    end

    test "evaluates decision that invokes BKM with literal body" do
      {200, body} =
        http_evaluate_decision("definitions_bkm_invoke_le", %{"income" => 50_000, "taxRate" => 0.2},
          decision_model_id: "Decision_tax"
        )

      assert body["result"] == 10_100
    end
  end

  describe "BKM with formal parameters" do
    setup do
      {201, _} = http_deploy_dmn("bkm_invocation_literal.dmn")
      :ok
    end

    test "formal parameters are bound from calling decision context" do
      {200, body} =
        http_evaluate_decision("definitions_bkm_invoke_le", %{"income" => 100_000, "taxRate" => 0.3},
          decision_model_id: "Decision_tax"
        )

      assert body["result"] == 30_100
    end
  end

  describe "BKM-to-BKM chain" do
    setup do
      {201, _} = http_deploy_dmn("bkm_chain.dmn")
      :ok
    end

    test "evaluates decision through BKM chain" do
      {200, body} =
        http_evaluate_decision("definitions_bkm_chain", %{"n" => 3, "m" => 7},
          decision_model_id: "Decision_main"
        )

      assert body["result"] == 38
    end
  end

  # ---------------------------------------------------------------------------
  # BKM error paths (deploy-time rejection)
  # ---------------------------------------------------------------------------

  describe "BKM cycle detection" do
    test "deploying a model with a BKM cycle returns validation error" do
      {status, body} = http_deploy_dmn("bkm_cycle.dmn")
      assert status in [400, 422]
      assert body["error"] in ["validation_failed", "dmn_parse_error"]
    end
  end

  describe "missing BKM reference" do
    test "deploying a model referencing non-existent BKM returns validation error" do
      {status, body} = http_deploy_dmn("bkm_missing_reference.dmn")
      assert status in [400, 422]
      assert body["error"] in ["validation_failed", "dmn_parse_error"]
    end
  end

  # ---------------------------------------------------------------------------
  # Cross-model import resolution
  # ---------------------------------------------------------------------------

  describe "import resolution — happy path" do
    test "evaluates importing model after deploying both models" do
      {201, _} = http_deploy_dmn("imported_helper.dmn")
      {201, _} = http_deploy_dmn("importing_model.dmn")

      {200, body} =
        http_evaluate_decision("definitions_importing", %{"base" => 5},
          decision_model_id: "Decision_final"
        )

      assert body["result"] == 20
    end

    test "imported decision result feeds into importing decision" do
      {201, _} = http_deploy_dmn("imported_helper.dmn")
      {201, _} = http_deploy_dmn("importing_model.dmn")

      {200, body} =
        http_evaluate_decision("definitions_importing", %{"base" => 7},
          decision_model_id: "Decision_final"
        )

      assert body["result"] == 24
    end
  end

  describe "import resolution — imported model not deployed" do
    test "deploying a model with unresolvable import fails at deploy time" do
      {status, body} = http_deploy_dmn("importing_missing.dmn")

      assert status in [400, 422]
      assert is_map(body)
      assert body["error"] in ["dmn_parse_error", "validation_failed"]
    end
  end

  # ---------------------------------------------------------------------------
  # Trace completeness for multi-decision evaluation
  # ---------------------------------------------------------------------------

  describe "trace completeness" do
    test "includeUnmatchedDetails with DRD shows decision-level traces" do
      {201, _} = http_deploy_dmn("drg_linear_chain.dmn")

      {200, body} =
        http_evaluate_decision("definitions_linear_chain", %{"x" => 5},
          decision_model_id: "Decision_A",
          include_unmatched_details: true
        )

      assert is_list(body["trace"]["decisions"])
      assert length(body["trace"]["decisions"]) == 2
    end
  end
end

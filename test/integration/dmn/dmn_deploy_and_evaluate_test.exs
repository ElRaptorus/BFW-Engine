defmodule EvilEngine.Integration.DMN.DmnDeployAndEvaluateTest do
  @moduledoc """
  Full-stack integration tests for DMN deploy, catalog CRUD, and ad-hoc evaluation.

  Exercises the HTTP pipeline end-to-end: `POST /decisions`, catalog routes,
  and `POST /decisions/{model_id}/evaluate` for all hit policies and error paths.
  """
  use EvilEngine.ExecutionCase, async: false

  @moduletag :integration

  @definitions_hit_policies "definitions_hit_policies"
  @definitions_discount "definitions_discount"
  @definitions_sum "definitions_sum"
  @definitions_bonus "definitions_bonus"
  @definitions_any_same "definitions_any_same"
  @definitions_unique_violation "definitions_unique_violation"
  @definitions_mixed "definitions_mixed"

  # -------------------------------------------------------------------------
  # Deploy pipeline
  # -------------------------------------------------------------------------

  describe "POST /decisions — deploy" do
    test "201 deploys a valid DMN model" do
      {201, body} = http_deploy_dmn("simple_unique.dmn")

      assert is_list(body["deployed"])
      assert length(body["deployed"]) == 1

      [deployed] = body["deployed"]
      assert deployed["decisionDefinitionId"] == @definitions_discount
      assert is_binary(deployed["version"])
    end

    test "400 when sources contains invalid XML" do
      {400, body} = http_deploy_dmn_xml("not valid xml at all")
      assert body["error"] == "dmn_parse_error"
    end

    test "201 when DMN has both table and literal — last-write-wins (A-0 semantics)" do
      {status, _body} = http_deploy_dmn("invalid_both_expressions.dmn")
      assert status == 201
    end

    test "422 when DMN has validation errors (no expression)" do
      {status, body} = http_deploy_dmn("invalid_no_expression.dmn")
      assert status in [400, 422]
      assert body["error"] in ["validation_failed", "dmn_parse_error"]
    end

    test "409 when redeploying same version" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")
      {409, body} = http_deploy_dmn("simple_unique.dmn")
      assert body["error"] == "decision_version_exists"
    end

    test "400 when sources key is missing" do
      {400, body} = http_deploy_dmn_raw(%{})
      assert body["error"] == "bad_request"
    end

    test "400 when sources is empty array" do
      {400, body} = http_deploy_dmn_raw(%{"sources" => []})
      assert body["error"] == "bad_request"
    end

    test "400 when sources contains non-string" do
      {400, body} = http_deploy_dmn_raw(%{"sources" => [123]})
      assert body["error"] == "bad_request"
    end
  end

  # -------------------------------------------------------------------------
  # Catalog CRUD
  # -------------------------------------------------------------------------

  describe "catalog CRUD" do
    test "GET /decisions lists deployed decision" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")

      {200, decisions} = http_list_decisions()
      assert is_list(decisions)
      assert Enum.any?(decisions, &(&1["id"] == @definitions_discount))
    end

    test "GET /decisions/:model_id shows detail" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")

      {200, detail} = http_show_decision(@definitions_discount)
      assert detail["id"] == @definitions_discount
      assert detail["name"] == "Discount Rules"
      assert is_binary(detail["version"])
      assert detail["enabled"] == true
    end

    test "GET /decisions/:model_id?includeXml=true includes dmn_xml" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")

      {200, detail} = http_show_decision(@definitions_discount, include_xml: true)
      assert is_binary(detail["dmnXml"])
      assert detail["dmnXml"] =~ "definitions_discount"
    end

    test "GET /decisions/:model_id/versions lists versions" do
      {201, deploy_body} = http_deploy_dmn("simple_unique.dmn")
      version = hd(deploy_body["deployed"])["version"]

      {200, versions} = http_list_decision_versions(@definitions_discount)
      assert is_list(versions)
      assert Enum.any?(versions, &(&1["version"] == version))
    end

    test "GET /decisions/:model_id/versions?includeXml=true includes dmn_xml" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")

      {200, versions} = http_list_decision_versions(@definitions_discount, include_xml: true)
      [version_entry | _] = versions
      assert is_binary(version_entry["dmnXml"])
    end

    test "GET /decisions/nonexistent returns 404" do
      {404, body} =
        http_show_decision("nonexistent_decision_#{System.unique_integer([:positive])}")

      assert body["error"] == "decision_definition_not_found"
    end

    test "GET /decisions/nonexistent/versions returns 404" do
      {404, body} =
        http_list_decision_versions("nonexistent_decision_#{System.unique_integer([:positive])}")

      assert body["error"] == "decision_definition_not_found"
    end

    test "PUT /decisions/:model_id/enable returns 204" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")
      {204, nil} = http_enable_decision(@definitions_discount)
    end

    test "PUT /decisions/:model_id/disable returns 204" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")
      {204, nil} = http_disable_decision(@definitions_discount)
    end

    test "DELETE /decisions/:model_id/versions/:version returns 204" do
      {201, deploy_body} = http_deploy_dmn("simple_unique.dmn")
      version = hd(deploy_body["deployed"])["version"]

      {204, nil} = http_delete_decision_version(@definitions_discount, version)
    end

    test "DELETE /decisions/:model_id undeploys all versions" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")
      {204, nil} = http_undeploy_decision(@definitions_discount)
    end

    test "DELETE /decisions/nonexistent returns 404" do
      {404, body} =
        http_undeploy_decision("nonexistent_decision_#{System.unique_integer([:positive])}")

      assert body["error"] == "not_found"
    end
  end

  # -------------------------------------------------------------------------
  # Evaluate — UNIQUE (all_hit_policies.dmn)
  # -------------------------------------------------------------------------

  describe "evaluate UNIQUE hit policy" do
    setup do
      {201, _} = http_deploy_dmn("all_hit_policies.dmn")
      :ok
    end

    test "value 5 matches low tier" do
      {200, body} =
        http_evaluate_decision(@definitions_hit_policies, %{"value" => 5},
          decision_model_id: "Decision_unique"
        )

      assert body["hitPolicy"] == "unique"
      assert body["result"]["result"] == "low"
    end

    test "value 25 matches medium tier" do
      {200, body} =
        http_evaluate_decision(@definitions_hit_policies, %{"value" => 25},
          decision_model_id: "Decision_unique"
        )

      assert body["hitPolicy"] == "unique"
      assert body["result"]["result"] == "medium"
    end

    test "value 75 matches high tier" do
      {200, body} =
        http_evaluate_decision(@definitions_hit_policies, %{"value" => 75},
          decision_model_id: "Decision_unique"
        )

      assert body["hitPolicy"] == "unique"
      assert body["result"]["result"] == "high"
    end
  end

  # -------------------------------------------------------------------------
  # Evaluate — FIRST
  # -------------------------------------------------------------------------

  describe "evaluate FIRST hit policy" do
    setup do
      {201, _} = http_deploy_dmn("all_hit_policies.dmn")
      :ok
    end

    test "value 50 returns first matching rule output" do
      {200, body} =
        http_evaluate_decision(@definitions_hit_policies, %{"value" => 50},
          decision_model_id: "Decision_first"
        )

      assert body["hitPolicy"] == "first"
      assert body["result"]["result"] == "first_match"
    end

    test "multi_input_first fixture returns high risk band" do
      {201, _} = http_deploy_dmn("multi_input_first.dmn")

      {200, body} =
        http_evaluate_decision("definitions_risk", %{
          "income" => 20_000,
          "creditScore" => 500,
          "yearsEmployed" => 1
        })

      assert body["hitPolicy"] == "first"
      assert body["result"]["riskCategory"] == "high"
    end
  end

  # -------------------------------------------------------------------------
  # Evaluate — ANY
  # -------------------------------------------------------------------------

  describe "evaluate ANY hit policy" do
    test "happy path when all matching rules share the same output" do
      {201, _} = http_deploy_dmn("any_same_output.dmn")

      {200, body} = http_evaluate_decision(@definitions_any_same, %{"value" => 10})
      assert body["hitPolicy"] == "any"
      assert body["result"]["result"] == "positive"
    end

    test "422 hit policy violation when matching rules differ" do
      {201, _} = http_deploy_dmn("all_hit_policies.dmn")

      {422, body} =
        http_evaluate_decision(@definitions_hit_policies, %{"value" => 10},
          decision_model_id: "Decision_any"
        )

      assert body["error"] == "dmn_evaluation_error"
      assert body["message"] =~ "different outputs"
    end
  end

  # -------------------------------------------------------------------------
  # Evaluate — COLLECT
  # -------------------------------------------------------------------------

  describe "evaluate COLLECT hit policy" do
    test "without aggregation returns list of output maps" do
      {201, _} = http_deploy_dmn("all_hit_policies.dmn")

      {200, body} =
        http_evaluate_decision(@definitions_hit_policies, %{"value" => 10},
          decision_model_id: "Decision_collect"
        )

      assert body["hitPolicy"] == "collect"
      assert body["result"] == [%{"result" => 1}, %{"result" => 2}]
    end

    test "with SUM aggregation returns numeric sum" do
      {201, _} = http_deploy_dmn("collect_with_sum.dmn")

      {200, body} =
        http_evaluate_decision(@definitions_bonus, %{"category" => "electronics"})

      assert body["hitPolicy"] == "collect"
      assert body["result"] == 15
    end
  end

  # -------------------------------------------------------------------------
  # Evaluate — RULE ORDER
  # -------------------------------------------------------------------------

  describe "evaluate RULE ORDER hit policy" do
    test "returns matched outputs in document order" do
      {201, _} = http_deploy_dmn("all_hit_policies.dmn")

      {200, body} =
        http_evaluate_decision(@definitions_hit_policies, %{"value" => 10},
          decision_model_id: "Decision_rule_order"
        )

      assert body["hitPolicy"] == "rule_order"
      assert body["result"] == [%{"result" => "rule_a"}, %{"result" => "rule_b"}]
    end

    test "multi_output_rule_order preserves multiple output columns" do
      {201, _} = http_deploy_dmn("multi_output_rule_order.dmn")

      {200, body} =
        http_evaluate_decision("definitions_multi_output", %{
          "amount" => 1500,
          "region" => "EU"
        })

      assert body["hitPolicy"] == "rule_order"
      [first_row] = body["result"]
      assert Map.has_key?(first_row, "warehouse")
      assert Map.has_key?(first_row, "priority")
      assert Map.has_key?(first_row, "fee")
    end
  end

  # -------------------------------------------------------------------------
  # Evaluate — OUTPUT ORDER
  # -------------------------------------------------------------------------

  describe "evaluate OUTPUT ORDER hit policy" do
    test "sorts results by output priority list" do
      {201, _} = http_deploy_dmn("all_hit_policies.dmn")

      {200, body} =
        http_evaluate_decision(@definitions_hit_policies, %{"value" => 10},
          decision_model_id: "Decision_output_order"
        )

      assert body["hitPolicy"] == "output_order"
      output_values = Enum.map(body["result"], & &1["grade"])
      assert output_values == ["A", "B"]
    end
  end

  # -------------------------------------------------------------------------
  # Evaluate — PRIORITY
  # -------------------------------------------------------------------------

  describe "evaluate PRIORITY hit policy" do
    test "returns highest-priority output from all_hit_policies" do
      {201, _} = http_deploy_dmn("all_hit_policies.dmn")

      {200, body} =
        http_evaluate_decision(@definitions_hit_policies, %{"value" => 10},
          decision_model_id: "Decision_priority"
        )

      assert body["hitPolicy"] == "priority"
      assert body["result"]["severity"] == "critical"
    end

    test "priority_hit_policy fixture returns critical for high score" do
      {201, _} = http_deploy_dmn("priority_hit_policy.dmn")

      {200, body} = http_evaluate_decision("definitions_priority", %{"score" => 95})
      assert body["hitPolicy"] == "priority"
      assert body["result"]["level"] == "critical"
    end
  end

  # -------------------------------------------------------------------------
  # Evaluate — literal expression
  # -------------------------------------------------------------------------

  describe "evaluate literal expression" do
    test "evaluates x + y FEEL expression" do
      {201, _} = http_deploy_dmn("literal_expression.dmn")

      {200, body} = http_evaluate_decision(@definitions_sum, %{"x" => 3, "y" => 7})
      assert body["hitPolicy"] == "literal"
      assert body["result"] == 10
    end
  end

  # -------------------------------------------------------------------------
  # Evaluate — UNIQUE no match
  # -------------------------------------------------------------------------

  describe "evaluate UNIQUE with no matching rules" do
    test "returns nil result when input matches no rule" do
      {201, _} = http_deploy_dmn("unique_violation.dmn")

      {200, body} = http_evaluate_decision(@definitions_unique_violation, %{"value" => -5})
      assert body["hitPolicy"] == "unique"
      assert body["result"] == nil
    end
  end

  # -------------------------------------------------------------------------
  # Evaluate — error paths
  # -------------------------------------------------------------------------

  describe "evaluate error paths" do
    test "404 for non-existent decision definition" do
      {404, body} =
        http_evaluate_decision("nonexistent_decision_#{System.unique_integer([:positive])}", %{})

      assert body["error"] == "decision_definition_not_found"
    end

    test "404 for wrong decisionModelId in deployed model" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")

      {404, body} =
        http_evaluate_decision(@definitions_discount, %{"age" => 25},
          decision_model_id: "Decision_nonexistent"
        )

      assert body["error"] in ["decision_not_found", "decision_definition_not_found"]
    end

    test "422 ambiguous_decision when model has multiple decisions and no decisionModelId" do
      {201, _} = http_deploy_dmn("all_hit_policies.dmn")

      {422, body} = http_evaluate_decision(@definitions_hit_policies, %{"value" => 10})
      assert body["error"] == "ambiguous_decision"
    end

    test "422 hit policy violation for UNIQUE with overlapping rules" do
      {201, _} = http_deploy_dmn("unique_violation.dmn")

      {422, body} =
        http_evaluate_decision(@definitions_unique_violation, %{"value" => 10})

      assert body["error"] == "dmn_evaluation_error"
      assert body["message"] =~ "UNIQUE"
    end

    test "422 when evaluating disabled decision with no active version" do
      {201, deploy_body} = http_deploy_dmn("simple_unique.dmn")
      version = hd(deploy_body["deployed"])["version"]
      {204, nil} = http_delete_decision_version(@definitions_discount, version)

      {404, body} = http_evaluate_decision(@definitions_discount, %{"age" => 25})
      assert body["error"] in ["no_active_version", "decision_definition_not_found"]
    end

    test "soft-deleting a version evicts it from the DMN ModelCache" do
      {201, deploy_body} = http_deploy_dmn("simple_unique.dmn")
      version = hd(deploy_body["deployed"])["version"]

      {:ok, definition} = EvilEngine.Api.get_decision_by_model_id(@definitions_discount)
      {:ok, decision_version} = EvilEngine.Api.find_decision_version_by_key(definition.id, version)
      version_id = decision_version.id

      assert {:ok, _definitions} = EvilEngine.DMN.ModelCache.fetch(version_id)

      {204, nil} = http_delete_decision_version(@definitions_discount, version)

      refute version_id in EvilEngine.DMN.ModelCache.list_cached_ids()
    end
  end

  # -------------------------------------------------------------------------
  # Evaluate — mixed multi-decision model
  # -------------------------------------------------------------------------

  describe "evaluate mixed_decisions model" do
    setup do
      {201, _} = http_deploy_dmn("mixed_decisions.dmn")
      :ok
    end

    test "evaluates table decision by decisionModelId" do
      {200, body} =
        http_evaluate_decision(@definitions_mixed, %{"x" => 5},
          decision_model_id: "Decision_table"
        )

      assert body["hitPolicy"] == "unique"
      assert body["result"]["y"] == 1
    end

    test "evaluates literal decision by decisionModelId" do
      {200, body} =
        http_evaluate_decision(@definitions_mixed, %{"x" => 3, "y" => 4},
          decision_model_id: "Decision_literal"
        )

      assert body["hitPolicy"] == "literal"
      assert body["result"] == 7
    end
  end

  # -------------------------------------------------------------------------
  # Evaluate — trace
  # -------------------------------------------------------------------------

  describe "evaluate trace" do
    test "normal evaluation includes trace with decisions, matched rules, and inputs" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")

      {200, body} = http_evaluate_decision(@definitions_discount, %{"age" => 25})

      assert is_list(body["trace"]["decisions"])
      assert length(body["trace"]["decisions"]) == 1

      [decision_trace] = body["trace"]["decisions"]
      assert decision_trace["decisionModelId"] == "Decision_discount"
      assert is_list(decision_trace["inputs"])
      assert decision_trace["inputs"] != []
      assert is_list(body["matchedRules"])
      assert length(body["matchedRules"]) == 1
    end

    test "includeUnmatchedDetails=true reports all rule traces" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")

      {200, body} =
        http_evaluate_decision(@definitions_discount, %{"age" => 25},
          include_unmatched_details: true
        )

      [decision_trace] = body["trace"]["decisions"]
      assert length(decision_trace["matchedRules"]) == 1
      assert length(decision_trace["unmatchedRules"]) == 2
      assert decision_trace["unmatchedRulesCount"] == 2
    end
  end

  # -------------------------------------------------------------------------
  # Evaluate by version (P8.2)
  # -------------------------------------------------------------------------

  describe "POST /decisions/:model_id/versions/:version/evaluate" do
    test "evaluates using a specific version" do
      {201, deploy_body} = http_deploy_dmn("simple_unique.dmn")
      [deployed] = deploy_body["deployed"]
      version = deployed["version"]

      {200, body} =
        http_evaluate_decision_by_version(@definitions_discount, version, %{"age" => 25})

      assert body["hitPolicy"] == "unique"
      assert is_map(body["result"])
      assert Map.has_key?(body["result"], "discount")
    end

    test "returns 404 for non-existent version string" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")

      {404, body} =
        http_evaluate_decision_by_version(@definitions_discount, "nonexistent-version", %{"age" => 25})

      assert body["error"] == "no_active_version"
    end

    test "returns 404 for non-existent decision id" do
      {404, body} =
        http_evaluate_decision_by_version(
          "nonexistent-decision-#{System.unique_integer([:positive])}",
          "1.0.0",
          %{"age" => 25}
        )

      assert body["error"] == "decision_definition_not_found"
    end

    test "supports decisionModelId parameter" do
      {201, deploy_body} = http_deploy_dmn("mixed_decisions.dmn")
      [deployed] = deploy_body["deployed"]
      version = deployed["version"]

      {200, body} =
        http_evaluate_decision_by_version(@definitions_mixed, version, %{"x" => 5},
          decision_model_id: "Decision_table"
        )

      assert body["hitPolicy"] == "unique"
      assert body["result"]["y"] == 1
    end

    test "returns 400 when input is not a map" do
      {201, deploy_body} = http_deploy_dmn("simple_unique.dmn")
      [deployed] = deploy_body["deployed"]
      version = deployed["version"]

      json_body = Jason.encode!(%{"input" => "not_a_map"})

      conn =
        Plug.Test.conn(
          :post,
          "/decisions/#{@definitions_discount}/versions/#{version}/evaluate",
          json_body
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(%{})}")
        |> route()

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "bad_request"
    end
  end

end

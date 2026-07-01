defmodule EvilEngine.DMN.DependencyResolverTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias EvilEngine.DMN.Evaluator.DependencyResolver
  alias EvilEngine.DMN.Model.Decision
  alias EvilEngine.DMN.Model.Definitions
  alias EvilEngine.DMN.Model.InformationRequirement
  alias EvilEngine.DMN.Model.LiteralExpression
  alias EvilEngine.DMN.Parser

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "dmns"])
  defp read_fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  defp parse_fixture(name) do
    {:ok, definitions} = Parser.parse(read_fixture(name))
    definitions
  end

  describe "resolve_evaluation_order/2" do
    test "linear chain orders upstream decision before target" do
      definitions = parse_fixture("drg_linear_chain.dmn")

      assert {:ok, ["Decision_B", "Decision_A"]} =
               DependencyResolver.resolve_evaluation_order("Decision_A", definitions)
    end

    test "diamond evaluates shared dependency once in order" do
      definitions = parse_fixture("drg_diamond.dmn")

      assert {:ok, evaluation_order} =
               DependencyResolver.resolve_evaluation_order("Decision_A", definitions)

      assert evaluation_order == ["Decision_D", "Decision_B", "Decision_C", "Decision_A"]
      assert Enum.count(evaluation_order, &(&1 == "Decision_D")) == 1
    end

    test "three-level chain includes all transitive dependencies" do
      definitions = parse_fixture("drg_three_level.dmn")

      assert {:ok, evaluation_order} =
               DependencyResolver.resolve_evaluation_order("Decision_A", definitions)

      assert evaluation_order == ["Decision_D", "Decision_C", "Decision_B", "Decision_A"]
    end

    test "cycle detection returns drg_cycle error" do
      definitions = parse_fixture("drg_cycle.dmn")

      assert {:error, :drg_cycle, %{decision_ids: cycle_decision_ids}} =
               DependencyResolver.resolve_evaluation_order("Decision_A", definitions)

      assert "Decision_A" in cycle_decision_ids
      assert "Decision_B" in cycle_decision_ids
    end

    test "missing required decision returns error" do
      decision_with_missing_dependency = %Decision{
        id: "Decision_orphan",
        name: "Orphan",
        information_requirements: [
          %InformationRequirement{
            id: "ir_missing",
            required_decision_id: "Decision_nonexistent"
          }
        ],
        expression: %LiteralExpression{id: "le", text: "1", compiled_ref: nil}
      }

      definitions = %Definitions{
        decisions: [decision_with_missing_dependency],
        input_data: [],
        raw_xml: ""
      }

      assert {:error, :missing_required_decision,
              %{decision_id: "Decision_nonexistent", required_by: "Decision_orphan"}} =
               DependencyResolver.resolve_evaluation_order("Decision_orphan", definitions)
    end

    test "single decision with no requirements returns single-item list" do
      definitions = parse_fixture("simple_unique.dmn")

      assert {:ok, ["Decision_discount"]} =
               DependencyResolver.resolve_evaluation_order("Decision_discount", definitions)
    end
  end
end

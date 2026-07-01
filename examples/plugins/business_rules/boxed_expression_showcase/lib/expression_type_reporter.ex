defmodule Examples.BusinessRules.BoxedExpressionShowcase.ExpressionTypeReporter do
  @moduledoc """
  Pure functions that map DMN decision trace entries to their CL3 expression types
  and build a structured showcase report.
  """

  @expression_types %{
    "Department Multiplier" => :decision_table,
    "Performance Bonus" => :boxed_invocation,
    "Certification Allowance" => :boxed_list,
    "Certification Total" => :literal_expression,
    "Benefits Package" => :boxed_context,
    "Salary Bands" => :relation,
    "Eligible for Promotion" => :boxed_conditional,
    "Qualified Certifications" => :boxed_filter,
    "Certification Details" => :boxed_for,
    "All Certs Premium" => :boxed_every,
    "Has Premium Cert" => :boxed_some,
    "Total Compensation" => :literal_expression
  }

  @doc "Builds a per-decision report from a normalized trace map with a `\"decisions\"` list."
  @spec build_report(map()) :: [map()]
  def build_report(trace) do
    decisions = Map.get(trace, "decisions", [])

    Enum.map(decisions, fn decision ->
      name = decision["decision_name"]

      %{
        decision: name,
        expression_type: Map.get(@expression_types, name, :unknown),
        hit_policy: decision["hit_policy"],
        result: decision["result"],
        duration_us: decision["duration_microseconds"]
      }
    end)
  end

  @doc "Returns the CL3 expression type atom for a decision display name, or `:unknown`."
  @spec expression_type_for(String.t()) :: atom()
  def expression_type_for(decision_name) do
    Map.get(@expression_types, decision_name, :unknown)
  end

  @doc "Returns all distinct expression type atoms from the catalog, sorted."
  @spec all_expression_types() :: [atom()]
  def all_expression_types do
    @expression_types
    |> Map.values()
    |> Enum.uniq()
    |> Enum.sort()
  end
end

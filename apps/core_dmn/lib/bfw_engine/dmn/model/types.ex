defmodule BfwEngine.DMN.Model.Types do
  @moduledoc """
  Shared type definitions for DMN model structs.

  The `expression_body()` union type enumerates every DMN expression
  variant that can appear as the value expression of a `Decision`,
  the body of a `FunctionDefinition`, or a nested child expression
  inside boxed expressions (Context entries, Invocation bindings, etc.).
  """

  alias BfwEngine.DMN.Model.BoxedConditional
  alias BfwEngine.DMN.Model.BoxedContext
  alias BfwEngine.DMN.Model.BoxedEvery
  alias BfwEngine.DMN.Model.BoxedFilter
  alias BfwEngine.DMN.Model.BoxedFor
  alias BfwEngine.DMN.Model.BoxedInvocation
  alias BfwEngine.DMN.Model.BoxedList
  alias BfwEngine.DMN.Model.BoxedSome
  alias BfwEngine.DMN.Model.DecisionTable
  alias BfwEngine.DMN.Model.FunctionDefinition
  alias BfwEngine.DMN.Model.LiteralExpression
  alias BfwEngine.DMN.Model.Relation

  @type expression_body ::
          DecisionTable.t()
          | LiteralExpression.t()
          | BoxedContext.t()
          | BoxedInvocation.t()
          | BoxedList.t()
          | Relation.t()
          | FunctionDefinition.t()
          | BoxedConditional.t()
          | BoxedFilter.t()
          | BoxedFor.t()
          | BoxedEvery.t()
          | BoxedSome.t()
end

defmodule EvilEngine.DMN.Model.Types do
  @moduledoc """
  Shared type definitions for DMN model structs.

  The `expression_body()` union type enumerates every DMN expression
  variant that can appear as the value expression of a `Decision`,
  the body of a `FunctionDefinition`, or a nested child expression
  inside boxed expressions (Context entries, Invocation bindings, etc.).
  """

  alias EvilEngine.DMN.Model.BoxedConditional
  alias EvilEngine.DMN.Model.BoxedContext
  alias EvilEngine.DMN.Model.BoxedEvery
  alias EvilEngine.DMN.Model.BoxedFilter
  alias EvilEngine.DMN.Model.BoxedFor
  alias EvilEngine.DMN.Model.BoxedInvocation
  alias EvilEngine.DMN.Model.BoxedList
  alias EvilEngine.DMN.Model.BoxedSome
  alias EvilEngine.DMN.Model.DecisionTable
  alias EvilEngine.DMN.Model.FunctionDefinition
  alias EvilEngine.DMN.Model.LiteralExpression
  alias EvilEngine.DMN.Model.Relation

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

defmodule BfwEngine.BPMN do
  @moduledoc """
  Public namespace for BPMN parsing, validation, and the in-memory
  Model cache.
  """

  use Boundary,
    deps: [BfwEngine.Types, BfwEngine.Expressions, BfwEngine.Timers],
    exports: [
      ComplexRegionAnalysis,
      InclusiveJoinAnalysis,
      LinterGate,
      Model.Definitions,
      Model.ErrorDefinition,
      Model.EscalationDefinition,
      Model.EventDefinition.Cancel,
      Model.EventDefinition.Compensation,
      Model.EventDefinition.Conditional,
      Model.EventDefinition.Error,
      Model.EventDefinition.Escalation,
      Model.EventDefinition.Link,
      Model.EventDefinition.Message,
      Model.EventDefinition.None,
      Model.EventDefinition.Signal,
      Model.EventDefinition.Terminate,
      Model.EventDefinition.Timer,
      Model.Extension,
      Model.FlowNode,
      Model.FlowNodeData.BoundaryEvent,
      Model.FlowNodeData.StartEvent,
      Model.FlowNodeData.SubProcess,
      Model.MultiInstance,
      Model.Process,
      Model.SequenceFlow,
      Model.StandardLoop,
      ModelCache
    ]

  alias BfwEngine.BPMN.Model.Definitions
  alias BfwEngine.BPMN.Parser
  alias BfwEngine.BPMN.Precompiler
  alias BfwEngine.BPMN.Validator

  @doc "Parse a BPMN XML binary into a `%Definitions{}` AST."
  @spec parse(String.t()) :: {:ok, Definitions.t()} | {:error, term()}
  defdelegate parse(xml), to: Parser

  @doc "Validate a previously parsed `%Definitions{}` struct."
  @spec validate(Definitions.t()) :: {:ok, Definitions.t()} | {:error, [Validator.violation()]}
  defdelegate validate(definitions), to: Validator

  @doc """
  Precompile FEEL expressions on MI/Loop structs within a Definitions AST.

  Best-effort: expressions that fail to compile are left as `nil`.
  Called automatically by `parse_and_validate/1`.
  """
  @spec precompile(Definitions.t()) :: Definitions.t()
  defdelegate precompile(definitions), to: Precompiler

  @doc """
  Parse a BPMN XML binary, validate, and precompile FEEL expressions.

  Returns `{:ok, %Definitions{}}` when parse and validation succeed, or
  `{:error, reason}` on the first failure. Precompilation is best-effort
  and never causes this function to return an error.
  """
  @spec parse_and_validate(String.t()) :: {:ok, Definitions.t()} | {:error, term()}
  def parse_and_validate(xml) do
    with {:ok, definitions} <- Parser.parse(xml),
         {:ok, definitions} <- Validator.validate(definitions) do
      {:ok, Precompiler.precompile(definitions)}
    end
  end
end

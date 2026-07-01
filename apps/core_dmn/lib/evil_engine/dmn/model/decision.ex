defmodule EvilEngine.DMN.Model.Decision do
  @moduledoc """
  A single decision within a DMN model.

  The value expression is stored in the unified `expression` field
  and must be exactly one of the `Types.expression_body()` variants
  (DecisionTable, LiteralExpression, or — from Phase 6 — any boxed
  expression type). This invariant is enforced by the Validator at
  deploy time and by a defensive guard in the Evaluator at runtime.
  """

  alias EvilEngine.DMN.Model.AuthorityRequirement
  alias EvilEngine.DMN.Model.InformationItem
  alias EvilEngine.DMN.Model.InformationRequirement
  alias EvilEngine.DMN.Model.KnowledgeRequirement
  alias EvilEngine.DMN.Model.Types

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          output_label: String.t() | nil,
          expression: Types.expression_body() | nil,
          information_requirements: [InformationRequirement.t()],
          knowledge_requirements: [KnowledgeRequirement.t()],
          authority_requirements: [AuthorityRequirement.t()],
          variable: InformationItem.t() | nil
        }

  @enforce_keys [:id]
  defstruct [
    :id,
    :name,
    :output_label,
    :expression,
    :variable,
    information_requirements: [],
    knowledge_requirements: [],
    authority_requirements: []
  ]

  @doc """
  Returns the name under which this decision's output should be stored
  in the shared evaluation context.

  Priority: `variable.name` > `name` > `id`.
  """
  @spec output_variable_name(t()) :: String.t()
  def output_variable_name(%__MODULE__{variable: %{name: name}}) when is_binary(name), do: name
  def output_variable_name(%__MODULE__{name: name}) when is_binary(name), do: name
  def output_variable_name(%__MODULE__{id: decision_id}), do: decision_id
end

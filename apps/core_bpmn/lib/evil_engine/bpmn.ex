defmodule EvilEngine.BPMN do
  @moduledoc """
  Public namespace for BPMN parsing, validation, and the in-memory
  Model cache.
  """

  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Parser
  alias EvilEngine.BPMN.Validator

  @doc "Parse a BPMN XML binary into a `%Definitions{}` AST."
  @spec parse(String.t()) :: {:ok, Definitions.t()} | {:error, term()}
  defdelegate parse(xml), to: Parser

  @doc "Validate a previously parsed `%Definitions{}` struct."
  @spec validate(Definitions.t()) :: {:ok, Definitions.t()} | {:error, [Validator.violation()]}
  defdelegate validate(definitions), to: Validator

  @doc """
  Parse a BPMN XML binary and then validate the result.

  Returns `{:ok, %Definitions{}}` when both steps succeed, or
  `{:error, reason}` on the first failure.
  """
  @spec parse_and_validate(String.t()) :: {:ok, Definitions.t()} | {:error, term()}
  def parse_and_validate(xml) do
    with {:ok, definitions} <- Parser.parse(xml) do
      Validator.validate(definitions)
    end
  end
end

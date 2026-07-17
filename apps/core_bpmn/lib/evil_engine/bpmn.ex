defmodule EvilEngine.BPMN do
  @moduledoc """
  Public namespace for BPMN parsing, validation, and the in-memory
  Model cache.
  """

  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Parser
  alias EvilEngine.BPMN.Precompiler
  alias EvilEngine.BPMN.Validator

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

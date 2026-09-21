defmodule BfwEngine.DMN do
  @moduledoc """
  Public namespace for DMN 1.5 parsing, validation, and the in-memory
  Model cache.

  ## Usage

      {:ok, definitions} = BfwEngine.DMN.parse(xml)
      {:ok, definitions} = BfwEngine.DMN.parse_and_validate(xml)
  """

  alias BfwEngine.DMN.Model.Definitions
  alias BfwEngine.DMN.Parser
  alias BfwEngine.DMN.Precompiler
  alias BfwEngine.DMN.Validator

  @doc "Parse a DMN XML binary into a `%Definitions{}` AST."
  @spec parse(String.t()) :: {:ok, Definitions.t()} | {:error, :dmn_parse_error, map()}
  def parse(xml), do: Parser.parse(xml)

  @doc "Validate a previously parsed `%Definitions{}` struct."
  @spec validate(Definitions.t()) :: {:ok, Definitions.t()} | {:error, :validation_failed, map()}
  def validate(definitions), do: Validator.validate(definitions)

  @doc """
  Parse a DMN XML binary, validate, and precompile all FEEL expressions.

  Accepts optional `opts` passed through to the precompiler (e.g.
  `import_resolver: resolver_fun` for cross-model context shape building).

  Returns `{:ok, %Definitions{}}` when all steps succeed, or
  `{:error, code, metadata}` on the first failure.
  """
  @spec parse_and_validate(String.t(), Precompiler.precompile_opts()) ::
          {:ok, Definitions.t()} | {:error, atom(), map()}
  def parse_and_validate(xml, opts \\ []) do
    with {:ok, definitions} <- parse(xml),
         {:ok, definitions} <- validate(definitions),
         do: Precompiler.precompile(definitions, opts)
  end
end

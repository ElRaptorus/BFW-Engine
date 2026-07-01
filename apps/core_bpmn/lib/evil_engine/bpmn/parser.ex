defmodule EvilEngine.BPMN.Parser do
  @moduledoc """
  SAX-based BPMN 2.0 XML parser.

  Accepts a BPMN XML binary and returns a typed
  `%EvilEngine.BPMN.Model.Definitions{}` AST. The heavy lifting
  is done by `EvilEngine.BPMN.Parser.SaxHandler`.
  """

  alias EvilEngine.BPMN.Parser.SaxHandler

  @doc """
  Parse a BPMN XML binary into a `%Definitions{}` AST.

  Returns `{:ok, %Definitions{}}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, EvilEngine.BPMN.Model.Definitions.t()} | {:error, term()}
  def parse(xml) when is_binary(xml) do
    initial_state = SaxHandler.initial_state(xml)

    case Saxy.parse_string(xml, SaxHandler, initial_state) do
      {:ok, state} -> {:ok, SaxHandler.finalize(state)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception ->
      {:error,
       %{
         exception: exception,
         element_id: nil,
         element_type: nil,
         phase: :parsing
       }}
  end

  def parse(_), do: {:error, :invalid_input}
end

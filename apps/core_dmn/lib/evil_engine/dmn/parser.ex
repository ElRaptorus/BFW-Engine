defmodule EvilEngine.DMN.Parser do
  @moduledoc """
  SAX-based DMN 1.5 XML parser.

  Delegates to `SaxHandler` for stream parsing via Saxy.
  Returns `{:ok, %Definitions{}}` or `{:error, reason}`.
  """

  alias EvilEngine.DMN.Model.Definitions
  alias EvilEngine.DMN.Parser.SaxHandler

  @spec parse(String.t()) :: {:ok, Definitions.t()} | {:error, :dmn_parse_error, map()}
  def parse(xml) when is_binary(xml) do
    initial_state = SaxHandler.initial_state(xml)

    case Saxy.parse_string(xml, SaxHandler, initial_state) do
      {:ok, state} -> {:ok, SaxHandler.finalize(state)}
      {:error, %{__exception__: true} = error} -> {:error, :dmn_parse_error, %{reason: Exception.message(error)}}
    end
  rescue
    exception ->
      {:error, :dmn_parse_error, %{reason: Exception.message(exception)}}
  end

  def parse(_), do: {:error, :dmn_parse_error, %{reason: "input must be a binary XML string"}}
end

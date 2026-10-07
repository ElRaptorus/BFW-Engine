defmodule BfwEngine.Execution.ProcessInstance.JsonSafe do
  @moduledoc """
  Converts runtime terms into JSON-safe values for persisted tokens and error details.
  """

  @spec convert(term()) :: nil | boolean() | binary() | number() | [any()] | map()
  def convert(nil), do: nil

  def convert(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  def convert(value) when is_atom(value), do: Atom.to_string(value)

  def convert(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&convert/1)

  def convert(value) when is_list(value), do: Enum.map(value, &convert/1)

  def convert(%{__struct__: _} = value) do
    value
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> convert()
  end

  def convert(value) when is_map(value) do
    Map.new(value, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), convert(v)}
      {k, v} when is_binary(k) -> {k, convert(v)}
      {k, v} -> {inspect(k), convert(v)}
    end)
  end

  def convert(value), do: inspect(value)
end

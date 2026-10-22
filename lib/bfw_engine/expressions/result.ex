defmodule BfwEngine.Expressions.Result do
  @moduledoc """
  Helpers for coercing FEEL evaluation results into engine-expected types.
  """

  @type t :: {:ok, term()} | {:error, String.t()}

  @doc """
  Coerces a FEEL result to a boolean.

  FEEL three-valued logic: `null` is treated as `false` for conditional
  branch decisions (sequence flow conditions, gateway activation, etc.).
  """
  @spec to_boolean(t()) :: {:ok, boolean()} | {:error, String.t()}
  def to_boolean({:ok, true}), do: {:ok, true}
  def to_boolean({:ok, false}), do: {:ok, false}
  def to_boolean({:ok, nil}), do: {:ok, false}
  def to_boolean({:error, _} = error), do: error

  def to_boolean({:ok, other}),
    do: {:error, "expected boolean, got: #{json_text(other)}"}

  @doc """
  Coerces a FEEL result to a string.
  """
  @spec to_string(t()) :: {:ok, String.t()} | {:error, String.t()}
  def to_string({:ok, value}) when is_binary(value), do: {:ok, value}
  def to_string({:ok, nil}), do: {:ok, nil}
  def to_string({:error, _} = error), do: error

  def to_string({:ok, other}),
    do: {:error, "expected string, got: #{inspect(other)}"}

  @doc """
  Coerces a FEEL result to a list.
  """
  @spec to_list(t()) :: {:ok, list()} | {:error, String.t()}
  def to_list({:ok, value}) when is_list(value), do: {:ok, value}
  def to_list({:ok, nil}), do: {:ok, []}
  def to_list({:error, _} = error), do: error

  def to_list({:ok, other}),
    do: {:error, "expected list, got: #{inspect(other)}"}

  @feel_temporal_kinds [
    :feel_date,
    :feel_time,
    :feel_datetime,
    :feel_duration_dt,
    :feel_duration_ym
  ]

  @doc """
  Renders a FEEL value as JSON text for diagnostics.

  A FEEL date, time, or duration (at any depth inside lists and maps) appears
  as its ISO 8601 text. A term JSON cannot encode falls back to `inspect/1`.
  """
  @spec json_text(term()) :: String.t()
  def json_text(value) do
    value |> temporals_as_text() |> Jason.encode!()
  rescue
    _exception -> inspect(value)
  end

  defp temporals_as_text({kind, text}) when kind in @feel_temporal_kinds and is_binary(text),
    do: text

  defp temporals_as_text(list) when is_list(list), do: Enum.map(list, &temporals_as_text/1)

  defp temporals_as_text(%{__struct__: _} = struct), do: struct

  defp temporals_as_text(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, temporals_as_text(value)} end)

  defp temporals_as_text(other), do: other

  @doc """
  Unwraps a successful result or returns the error.
  """
  @spec unwrap!(t()) :: term()
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, reason}), do: raise(reason)
end

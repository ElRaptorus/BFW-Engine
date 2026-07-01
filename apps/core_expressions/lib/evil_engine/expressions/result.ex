defmodule EvilEngine.Expressions.Result do
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
    do: {:error, "expected boolean, got: #{inspect(other)}"}

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

  @doc """
  Unwraps a successful result or returns the error.
  """
  @spec unwrap!(t()) :: term()
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, reason}), do: raise(reason)
end

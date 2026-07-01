defmodule FeelNif do
  @moduledoc """
  NIF bridge to the dsntk FEEL evaluator (Rust).
  """
  use Rustler, otp_app: :feel_nif_spike, crate: :feel_nif

  @doc "Parse and compile a FEEL expression with a context for name resolution. Returns {:ok, ref} | {:error, reason}."
  def compile(_expression, _context), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Evaluate a compiled expression against a context map. Returns {:ok, value} | {:error, reason}."
  def eval_compiled(_compiled_ref, _context), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Parse and evaluate a FEEL expression in one shot. Returns {:ok, value} | {:error, reason}."
  def eval_expression(_expression, _context), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Evaluate a FEEL unary test. Returns {:ok, boolean} | {:error, reason}."
  def eval_unary_test(_expression, _input, _context), do: :erlang.nif_error(:nif_not_loaded)
end

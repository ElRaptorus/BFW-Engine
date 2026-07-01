defmodule EvilEngine.Expressions.Nif do
  @moduledoc false

  use Rustler, otp_app: :core_expressions, crate: :feel_nif

  @doc false
  def compile(_expression, _context), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def eval_compiled(_compiled_ref, _context), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def eval_expression(_expression, _context), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def eval_unary_test(_expression, _input, _context), do: :erlang.nif_error(:nif_not_loaded)
end

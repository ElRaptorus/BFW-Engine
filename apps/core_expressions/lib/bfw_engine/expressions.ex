defmodule BfwEngine.Expressions do
  @moduledoc """
  Public API for the FEEL expression evaluator.

  Backed by a Rust NIF wrapping the dsntk FEEL crates via Rustler.
  Expressions are precompiled at deploy time into an opaque reference
  that can be evaluated repeatedly against different runtime contexts
  without re-parsing.

  ## Precompilation

  The FEEL parser is scope-aware: it needs to know which variable names
  exist at parse time to disambiguate FEEL's context-sensitive grammar.
  `compile/2` therefore takes a context shape (map with placeholder
  values) alongside the expression string. The engine passes the
  seven-binding root shape at deploy time.

  ## Evaluation

  `evaluate/2` takes the compiled reference and a `Context` struct,
  converts it to the flat map the NIF expects, and returns the result.
  """

  alias BfwEngine.Expressions.Context
  alias BfwEngine.Expressions.Nif

  @doc """
  Compiles a FEEL expression string into an opaque reference.

  The `context_shape` must be a `%{String.t() => term()}` map that
  contains at least the variable names the expression references.
  Values may be placeholders (e.g. `nil`, `0`, `%{}`).

  Returns `{:ok, reference}` on success, `{:error, reason}` on
  parse failure.
  """
  @spec compile(String.t(), map()) :: {:ok, reference()} | {:error, String.t()}
  def compile(expression, context_shape \\ %{})
      when is_binary(expression) and is_map(context_shape) do
    Nif.compile(expression, context_shape)
  end

  @doc """
  Evaluates a previously compiled expression against a runtime context.

  Accepts a `%Context{}` struct (BPMN runtime bindings) or a flat
  string-keyed map (DMN input context and other ad-hoc scopes).

  Returns `{:ok, value}` or `{:error, reason}`.
  """
  @spec evaluate(reference(), Context.t() | map()) :: {:ok, term()} | {:error, String.t()}
  def evaluate(compiled_ref, %Context{} = context) do
    Nif.eval_compiled(compiled_ref, Context.to_feel_scope(context))
  end

  def evaluate(compiled_ref, context) when is_map(context) do
    Nif.eval_compiled(compiled_ref, stringify_map_keys(context))
  end

  @doc """
  Parses and evaluates a FEEL expression in one shot.

  Useful for one-off evaluations (e.g. in tests or when precompilation
  overhead is not justified). For hot-path usage, prefer `compile/2`
  followed by `evaluate/2`.

  Returns `{:ok, value}` or `{:error, reason}`.
  """
  @spec eval(String.t(), Context.t() | map()) :: {:ok, term()} | {:error, String.t()}
  def eval(expression, %Context{} = context) when is_binary(expression) do
    Nif.eval_expression(expression, Context.to_feel_scope(context))
  end

  def eval(expression, context) when is_binary(expression) and is_map(context) do
    Nif.eval_expression(expression, context)
  end

  @doc """
  Evaluates a FEEL unary test against an input value.

  Used for DMN-style decision table cells and gateway conditions
  written in unary-test syntax (e.g. `< 100`, `[1..5]`).

  Returns `{:ok, value}` or `{:error, reason}`.
  """
  @spec evaluate_unary(String.t(), term(), map()) :: {:ok, term()} | {:error, String.t()}
  def evaluate_unary(expression, input, context \\ %{})
      when is_binary(expression) and is_map(context) do
    Nif.eval_unary_test(expression, input, context)
  end

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end

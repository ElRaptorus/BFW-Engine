defmodule BfwEngine.Execution.FlowNodes.TimerSpecResolver do
  @moduledoc """
  Resolves the `timeDate`, `timeDuration`, and `timeCycle` text of a Timer
  event definition for the timer handlers (catch, boundary, start, Event
  Subprocess start).

  Text shaped like an ISO 8601 value of its kind (a date or date-time for
  `timeDate`, a `P…` duration for `timeDuration`, an `R<n>/…` repeating
  interval for `timeCycle`) is read as a static value; a date-only `timeDate`
  is midnight UTC. Any other text is a FEEL expression evaluated against the
  handler's bindings. A FEEL date-time, duration, or string result is
  converted with `BfwEngine.Expressions.to_datetime/1` and `to_duration/1`
  (a FEEL date-time without an offset is read as UTC); a `timeCycle`
  expression must yield a string. A FEEL evaluation error is returned as
  `{:timer_expression_failed, expression, message}`.
  """

  alias BfwEngine.Expressions
  alias BfwEngine.Expressions.Context, as: FeelContext
  alias BfwEngine.Timers.ISO8601

  @doc """
  Resolves a `timeDate` or `timeDuration` into the fire time. A duration is
  added to `reference_time`.

  Returns `{:ok, fire_at}` or `{:error, reason}`.
  """
  @spec resolve_fire_at(:date | :duration, String.t(), FeelContext.t(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, term()}
  def resolve_fire_at(kind, spec_string, feel_context, reference_time) do
    trimmed_spec = String.trim(spec_string)

    if iso_shaped?(kind, trimmed_spec) do
      ISO8601.resolve_fire_at(kind, trimmed_spec, reference_time)
    else
      with {:ok, value} <- evaluate(spec_string, feel_context) do
        fire_at_from_value(kind, value, reference_time)
      end
    end
  end

  @doc """
  Resolves a `timeCycle` into a cycle spec.

  Returns `{:ok, cycle_spec}` or `{:error, reason}`.
  """
  @spec resolve_cycle(String.t(), FeelContext.t()) ::
          {:ok, ISO8601.cycle_spec()} | {:error, term()}
  def resolve_cycle(spec_string, feel_context) do
    trimmed_spec = String.trim(spec_string)

    if iso_shaped?(:cycle, trimmed_spec) do
      ISO8601.parse_cycle(trimmed_spec)
    else
      case evaluate(spec_string, feel_context) do
        {:ok, cycle_string} when is_binary(cycle_string) -> ISO8601.parse_cycle(cycle_string)
        {:ok, value} -> {:error, {:not_a_cycle, value}}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Wraps a resolution error for a timer handler: `:timer_expression_failed`
  for a FEEL evaluation error, `:timer_resolution_failed` otherwise.
  """
  @spec failure(term()) :: %{
          reason: :timer_expression_failed | :timer_resolution_failed,
          detail: term()
        }
  def failure({:timer_expression_failed, _expression, _message} = reason),
    do: %{reason: :timer_expression_failed, detail: reason}

  def failure(reason), do: %{reason: :timer_resolution_failed, detail: reason}

  defp iso_shaped?(:date, text), do: Regex.match?(~r/^\d{4}-\d{2}-\d{2}([T ]|$)/, text)
  defp iso_shaped?(:duration, text), do: Regex.match?(~r/^-?P[0-9YMWDTHS.,]*$/, text)
  defp iso_shaped?(:cycle, text), do: Regex.match?(~r/^R\d*\//, text)

  defp fire_at_from_value(:date, value, _reference_time), do: Expressions.to_datetime(value)

  defp fire_at_from_value(:duration, value, reference_time) do
    with {:ok, duration} <- Expressions.to_duration(value) do
      {:ok, DateTime.shift(reference_time, duration)}
    end
  end

  defp evaluate(spec_string, feel_context) do
    case Expressions.eval(spec_string, feel_context) do
      {:ok, value} -> {:ok, value}
      {:error, message} -> {:error, {:timer_expression_failed, spec_string, message}}
    end
  end
end

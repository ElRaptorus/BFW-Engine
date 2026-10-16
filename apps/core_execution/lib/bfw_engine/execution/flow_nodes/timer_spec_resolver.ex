defmodule BfwEngine.Execution.FlowNodes.TimerSpecResolver do
  @moduledoc """
  Resolves the `timeDate`, `timeDuration`, and `timeCycle` text of a Timer
  event definition for the timer handlers (catch, boundary, start, Event
  Subprocess start).

  The text is first evaluated as FEEL against the handler's bindings. A FEEL
  date-time, duration, or string result is converted with
  `BfwEngine.Expressions.to_datetime/1` and `to_duration/1` (a FEEL date-time
  without an offset is read as UTC); a `timeCycle` expression must yield a
  string. When FEEL yields `null` or cannot parse the text, the text itself is
  read as a static ISO 8601 value.
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
    case evaluate(spec_string, feel_context) do
      {:ok, value} -> fire_at_from_value(kind, value, reference_time)
      :static -> ISO8601.resolve_fire_at(kind, spec_string, reference_time)
    end
  end

  @doc """
  Resolves a `timeCycle` into a cycle spec.

  Returns `{:ok, cycle_spec}` or `{:error, reason}`.
  """
  @spec resolve_cycle(String.t(), FeelContext.t()) ::
          {:ok, ISO8601.cycle_spec()} | {:error, term()}
  def resolve_cycle(spec_string, feel_context) do
    case evaluate(spec_string, feel_context) do
      {:ok, cycle_string} when is_binary(cycle_string) -> ISO8601.parse_cycle(cycle_string)
      {:ok, value} -> {:error, {:not_a_cycle, value}}
      :static -> ISO8601.parse_cycle(spec_string)
    end
  end

  defp fire_at_from_value(:date, value, _reference_time), do: Expressions.to_datetime(value)

  defp fire_at_from_value(:duration, value, reference_time) do
    with {:ok, duration} <- Expressions.to_duration(value) do
      {:ok, DateTime.shift(reference_time, duration)}
    end
  end

  defp evaluate(spec_string, feel_context) do
    case Expressions.eval(spec_string, feel_context) do
      {:ok, nil} -> :static
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> :static
    end
  rescue
    _exception -> :static
  end
end

defmodule BfwEngine.Execution.DurationHelper do
  @moduledoc """
  Shared ISO 8601 duration parsing utilities for execution handlers.
  """

  @spec parse_duration_to_ms(String.t()) :: {:ok, non_neg_integer()} | {:error, :invalid_duration}
  def parse_duration_to_ms(duration_string) do
    case Duration.from_iso8601(duration_string) do
      {:ok, duration} -> {:ok, duration_to_ms(duration)}
      {:error, _reason} -> {:error, :invalid_duration}
    end
  end

  @spec duration_to_ms(Duration.t()) :: integer()
  def duration_to_ms(%Duration{} = duration) do
    now = DateTime.utc_now()
    future = DateTime.shift(now, duration)
    DateTime.diff(future, now, :millisecond)
  end
end

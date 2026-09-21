defmodule BfwEngine.Timers.ISO8601 do
  @moduledoc """
  Pure ISO 8601 parser for timer specifications.

  Converts raw ISO 8601 spec strings into concrete `DateTime` fire-at
  values. Handles three kinds:

  - `:date` — Absolute datetime (`2026-06-01T10:00:00Z`)
  - `:duration` — Duration relative to a reference time (`PT1H30M`, `P1DT12H`)
  - `:cycle` — Recurring timer (`R3/PT1H`, `R/2026-06-01T10:00:00Z/PT1H`)

  This module has no FEEL awareness and no BPMN awareness. It operates
  exclusively on ISO 8601 strings and Elixir datetime/duration types.
  """

  @type cycle_spec :: %{
          repetitions: pos_integer() | :infinite,
          interval_duration: Duration.t(),
          start_at: DateTime.t() | nil
        }

  @doc """
  Resolves an ISO 8601 spec string into a concrete fire-at DateTime.

  ## Parameters

  - `kind` — `:date`, `:duration`, or `:cycle`
  - `spec_string` — the raw ISO 8601 string
  - `reference_time` — anchor for duration calculations (typically `DateTime.utc_now()`)

  ## Returns

  - `{:ok, DateTime.t()}` for `:date` and `:duration`
  - `{:ok, {:cycle, cycle_spec()}}` for `:cycle`
  - `{:error, term()}` on parse failure
  """
  @spec resolve_fire_at(:date | :duration | :cycle, String.t(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:ok, {:cycle, cycle_spec()}} | {:error, term()}
  def resolve_fire_at(:date, spec_string, _reference_time) do
    case DateTime.from_iso8601(spec_string) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, {:invalid_date, reason}}
    end
  end

  def resolve_fire_at(:duration, spec_string, reference_time) do
    case Duration.from_iso8601(spec_string) do
      {:ok, duration} ->
        fire_at = DateTime.shift(reference_time, duration)
        {:ok, fire_at}

      {:error, reason} ->
        {:error, {:invalid_duration, reason}}
    end
  end

  def resolve_fire_at(:cycle, spec_string, _reference_time) do
    case parse_cycle(spec_string) do
      {:ok, cycle_spec} ->
        {:ok, {:cycle, cycle_spec}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Computes the next fire time for a cycle, given the last fire time.

  Returns `nil` when repetitions are exhausted (finite cycle fully consumed).
  Decrements `cycle_remaining` for finite cycles.
  """
  @spec next_cycle_fire(cycle_spec(), DateTime.t()) :: {DateTime.t(), cycle_spec()} | nil
  def next_cycle_fire(%{repetitions: :infinite} = cycle_spec, last_fire_at) do
    next_fire = DateTime.shift(last_fire_at, cycle_spec.interval_duration)
    {next_fire, cycle_spec}
  end

  def next_cycle_fire(%{repetitions: remaining} = cycle_spec, last_fire_at) when remaining > 1 do
    next_fire = DateTime.shift(last_fire_at, cycle_spec.interval_duration)
    updated_spec = %{cycle_spec | repetitions: remaining - 1}
    {next_fire, updated_spec}
  end

  def next_cycle_fire(%{repetitions: remaining}, _last_fire_at) when remaining <= 1 do
    nil
  end

  @doc """
  Computes the first fire time for a cycle spec.

  If `start_at` is set, the first fire is `start_at + interval_duration`.
  Otherwise, the first fire is `reference_time + interval_duration`.
  """
  @spec first_fire_at(cycle_spec(), DateTime.t()) :: DateTime.t()
  def first_fire_at(%{start_at: nil} = cycle_spec, reference_time) do
    DateTime.shift(reference_time, cycle_spec.interval_duration)
  end

  def first_fire_at(%{start_at: start_at} = cycle_spec, _reference_time) do
    DateTime.shift(start_at, cycle_spec.interval_duration)
  end

  @doc """
  Parses the `R[n]/[start]/P...` cycle format into a structured spec.

  Supported formats:

  - `R3/PT1H` — repeat 3 times with 1-hour interval, no explicit start
  - `R/PT1H` — infinite repeats with 1-hour interval
  - `R3/2026-06-01T10:00:00Z/PT1H` — 3 repeats starting from a specific date
  - `R/2026-06-01T10:00:00Z/PT1H` — infinite repeats from a specific date
  """
  @spec parse_cycle(String.t()) :: {:ok, cycle_spec()} | {:error, term()}
  def parse_cycle(spec_string) do
    case String.split(spec_string, "/") do
      [repetition_part, duration_part] ->
        with {:ok, repetitions} <- parse_repetitions(repetition_part),
             {:ok, duration} <- parse_duration(duration_part) do
          {:ok, %{repetitions: repetitions, interval_duration: duration, start_at: nil}}
        end

      [repetition_part, start_or_duration, duration_part] ->
        with {:ok, repetitions} <- parse_repetitions(repetition_part),
             {:ok, start_at} <- parse_start_datetime(start_or_duration),
             {:ok, duration} <- parse_duration(duration_part) do
          {:ok, %{repetitions: repetitions, interval_duration: duration, start_at: start_at}}
        end

      _other ->
        {:error, {:invalid_cycle_format, spec_string}}
    end
  end

  defp parse_repetitions("R"), do: {:ok, :infinite}

  defp parse_repetitions("R" <> count_string) do
    case Integer.parse(count_string) do
      {count, ""} when count > 0 -> {:ok, count}
      {count, ""} when count <= 0 -> {:error, {:invalid_repetition_count, count}}
      _other -> {:error, {:invalid_repetition_format, "R" <> count_string}}
    end
  end

  defp parse_repetitions(other), do: {:error, {:invalid_repetition_format, other}}

  defp parse_duration("P" <> _rest = duration_string) do
    case Duration.from_iso8601(duration_string) do
      {:ok, duration} -> {:ok, duration}
      {:error, reason} -> {:error, {:invalid_duration, reason}}
    end
  end

  defp parse_duration(other), do: {:error, {:invalid_duration_format, other}}

  defp parse_start_datetime(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, {:invalid_start_datetime, reason}}
    end
  end
end

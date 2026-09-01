defmodule Examples.BusinessRules.DecisionAnalytics.AnomalyDetector do
  @moduledoc """
  Rolling-window latency spike detector for DMN evaluations.

  A sample is an anomaly when `current_latency / rolling_average` is at or
  above `spike_threshold` (default `3`) over the last `window_size` samples
  (default `20`).
  """

  @default_window_size 20
  @default_spike_threshold 3

  @type t :: %__MODULE__{
          window_size: pos_integer(),
          spike_threshold: number()
        }

  @type result :: %{
          is_anomaly: boolean(),
          current_latency: number(),
          rolling_average: number(),
          spike_factor: float(),
          decision_ref: String.t()
        }

  defstruct window_size: @default_window_size, spike_threshold: @default_spike_threshold

  @doc "Builds a detector. Options: `:window_size`, `:spike_threshold`."
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      window_size: Keyword.get(options, :window_size, @default_window_size),
      spike_threshold: Keyword.get(options, :spike_threshold, @default_spike_threshold)
    }
  end

  @doc "Evaluates `current_latency` against the rolling window of `latencies`."
  @spec detect(t(), String.t(), [number()], number()) :: result()
  def detect(%__MODULE__{} = detector, decision_ref, latencies, current_latency)
      when is_binary(decision_ref) and is_list(latencies) and is_number(current_latency) do
    recent_window = Enum.take(latencies, -detector.window_size)

    if recent_window == [] do
      %{
        is_anomaly: false,
        current_latency: current_latency,
        rolling_average: 0,
        spike_factor: 0.0,
        decision_ref: decision_ref
      }
    else
      rolling_average = Enum.sum(recent_window) / length(recent_window)

      spike_factor =
        if rolling_average > 0 do
          current_latency / rolling_average
        else
          0
        end

      %{
        is_anomaly: spike_factor >= detector.spike_threshold,
        current_latency: current_latency,
        rolling_average: round(rolling_average),
        spike_factor: Float.round(spike_factor * 1.0, 2),
        decision_ref: decision_ref
      }
    end
  end
end

defmodule Examples.BusinessRules.DecisionAnalytics.LatencyHistogram do
  @moduledoc """
  In-memory latency histogram used by `ReportFormatter` for average, percentile,
  min, and max calculations over collected DMN evaluation durations.
  """

  defstruct values: []

  @type t :: %__MODULE__{values: [number()]}

  @doc "Returns an empty histogram."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Appends one sample to the histogram."
  @spec add(t(), number()) :: t()
  def add(%__MODULE__{values: values} = histogram, value) when is_number(value) do
    %{histogram | values: values ++ [value]}
  end

  @doc "Appends many samples to the histogram."
  @spec add_all(t(), [number()]) :: t()
  def add_all(%__MODULE__{values: values} = histogram, extra_values) when is_list(extra_values) do
    %{histogram | values: values ++ extra_values}
  end

  @doc "Number of samples."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{values: values}), do: length(values)

  @doc "Arithmetic mean of samples, or `0` when empty."
  @spec average(t()) :: number()
  def average(%__MODULE__{values: []}), do: 0

  def average(%__MODULE__{values: values}) do
    Enum.sum(values) / length(values)
  end

  @doc "Nearest-rank percentile of the samples, or `0` when empty."
  @spec percentile(t(), number()) :: number()
  def percentile(%__MODULE__{values: []}, _percentile_rank), do: 0

  def percentile(%__MODULE__{values: values}, percentile_rank) do
    sorted_values = Enum.sort(values)
    index = max(0, ceil(length(sorted_values) * percentile_rank / 100) - 1)
    Enum.at(sorted_values, index)
  end

  @doc "95th percentile."
  @spec p95(t()) :: number()
  def p95(histogram), do: percentile(histogram, 95)

  @doc "99th percentile."
  @spec p99(t()) :: number()
  def p99(histogram), do: percentile(histogram, 99)

  @doc "Minimum sample, or `0` when empty."
  @spec min(t()) :: number()
  def min(%__MODULE__{values: []}), do: 0
  def min(%__MODULE__{values: values}), do: Enum.min(values)

  @doc "Maximum sample, or `0` when empty."
  @spec max(t()) :: number()
  def max(%__MODULE__{values: []}), do: 0
  def max(%__MODULE__{values: values}), do: Enum.max(values)
end

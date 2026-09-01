defmodule Examples.BusinessRules.DecisionAnalytics.AnalyticsCollector do
  @moduledoc """
  Agent-backed per-decision analytics for DMN Business Rule Task evaluations.

  Tracks evaluation counts, latency samples, and rule-hit distribution. Pass
  the collected stats through `ReportFormatter.format/1` for periodic reports.
  """

  use Agent

  @default_name __MODULE__

  @type observation :: %{
          optional(:decision_ref) => String.t(),
          optional(:duration_us) => non_neg_integer(),
          optional(:matched_rules) => [term()]
        }

  @type decision_stats :: %{
          decision_ref: String.t(),
          evaluation_count: non_neg_integer(),
          total_duration_us: non_neg_integer(),
          latencies: [non_neg_integer()],
          rule_hit_counts: %{String.t() => non_neg_integer()},
          last_seen: DateTime.t()
        }

  @doc "Starts the analytics collector agent. Options: `:name` (default `AnalyticsCollector`)."
  def start_link(options \\ []) do
    agent_name = Keyword.get(options, :name, @default_name)
    Agent.start_link(fn -> %{} end, name: agent_name)
  end

  @doc "Records one DMN evaluation observation into per-decision aggregates."
  @spec record(observation(), keyword()) :: :ok
  def record(observation, options \\ []) do
    agent_name = Keyword.get(options, :name, @default_name)

    Agent.update(agent_name, fn stats ->
      apply_observation(stats, observation)
    end)
  end

  @doc "Returns the full per-decision stats map keyed by decision reference."
  @spec get_stats(keyword()) :: %{String.t() => decision_stats()}
  def get_stats(options \\ []) do
    agent_name = Keyword.get(options, :name, @default_name)
    Agent.get(agent_name, & &1)
  end

  @doc "Returns stats for one decision reference, or `nil` when unseen."
  @spec get_stats_for_decision(String.t(), keyword()) :: decision_stats() | nil
  def get_stats_for_decision(decision_ref, options \\ []) do
    agent_name = Keyword.get(options, :name, @default_name)
    Agent.get(agent_name, &Map.get(&1, decision_ref))
  end

  @doc "Clears all collected analytics."
  @spec reset(keyword()) :: :ok
  def reset(options \\ []) do
    agent_name = Keyword.get(options, :name, @default_name)
    Agent.update(agent_name, fn _stats -> %{} end)
  end

  defp apply_observation(stats, observation) do
    decision_ref = Map.get(observation, :decision_ref) || "unknown"
    duration_microseconds = Map.get(observation, :duration_us, 0) || 0
    matched_rule_identifiers = matched_rule_identifiers(observation)
    occurred_at = DateTime.utc_now()

    existing = Map.get(stats, decision_ref, empty_stats(decision_ref, occurred_at))

    updated_rule_hit_counts =
      Enum.reduce(matched_rule_identifiers, existing.rule_hit_counts, fn rule_identifier,
                                                                         rule_hit_counts ->
        Map.update(rule_hit_counts, rule_identifier, 1, &(&1 + 1))
      end)

    updated_stats = %{
      existing
      | evaluation_count: existing.evaluation_count + 1,
        total_duration_us: existing.total_duration_us + duration_microseconds,
        latencies: existing.latencies ++ [duration_microseconds],
        rule_hit_counts: updated_rule_hit_counts,
        last_seen: occurred_at
    }

    Map.put(stats, decision_ref, updated_stats)
  end

  defp empty_stats(decision_ref, occurred_at) do
    %{
      decision_ref: decision_ref,
      evaluation_count: 0,
      total_duration_us: 0,
      latencies: [],
      rule_hit_counts: %{},
      last_seen: occurred_at
    }
  end

  defp matched_rule_identifiers(observation) do
    case Map.get(observation, :matched_rules) do
      rules when is_list(rules) -> Enum.map(rules, &normalize_rule_identifier/1)
      _other -> []
    end
  end

  defp normalize_rule_identifier(rule_identifier) when is_binary(rule_identifier),
    do: rule_identifier

  defp normalize_rule_identifier(%{rule_id: rule_identifier}) when is_binary(rule_identifier),
    do: rule_identifier

  defp normalize_rule_identifier(%{"rule_id" => rule_identifier}) when is_binary(rule_identifier),
    do: rule_identifier

  defp normalize_rule_identifier(rule_identifier) when is_atom(rule_identifier),
    do: Atom.to_string(rule_identifier)

  defp normalize_rule_identifier(rule_identifier), do: inspect(rule_identifier)
end

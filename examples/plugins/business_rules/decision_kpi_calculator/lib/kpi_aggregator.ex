defmodule Examples.BusinessRules.KpiCalculator.KpiAggregator do
  @moduledoc """
  Agent-backed running aggregates for DMN Business Rule Task evaluations.

  Tracks per-decision latency distributions, rule hit counts, and global
  evaluation totals. Call `get_stats/0` for the raw state map and pass
  per-decision entries through `StatsFormatter.format/2` for reports.
  """

  use Agent

  @default_name __MODULE__

  @type record_map :: %{
          optional(:decision_ref) => String.t(),
          optional(:duration_us) => non_neg_integer(),
          optional(:hit_policy) => String.t(),
          optional(:matched_rule_count) => non_neg_integer(),
          optional(:matched_rules) => [String.t()],
          optional(:process_instance_id) => String.t(),
          optional(:occurred_at) => DateTime.t(),
          optional(:terminal_state) => atom(),
          optional(:total_rule_count) => pos_integer(),
          optional(:error) => boolean()
        }

  @doc "Starts the KPI aggregator agent. Options: `:name` (default `KpiAggregator`)."
  def start_link(options \\ []) do
    agent_name = Keyword.get(options, :name, @default_name)
    Agent.start_link(fn -> initial_state() end, name: agent_name)
  end

  @doc "Records one DMN evaluation observation into running aggregates."
  @spec record(record_map(), keyword()) :: :ok
  def record(record, options \\ []) do
    agent_name = Keyword.get(options, :name, @default_name)

    Agent.cast(agent_name, fn state ->
      apply_record(state, record)
    end)
  end

  @doc "Returns the full aggregator state map."
  @spec get_stats(keyword()) :: map()
  def get_stats(options \\ []) do
    agent_name = Keyword.get(options, :name, @default_name)
    Agent.get(agent_name, & &1)
  end

  @doc "Resets all per-decision and global aggregates."
  @spec reset(keyword()) :: :ok
  def reset(options \\ []) do
    agent_name = Keyword.get(options, :name, @default_name)
    Agent.update(agent_name, fn _state -> initial_state() end)
  end

  defp initial_state do
    %{
      per_decision: %{},
      global: %{
        total_evaluations: 0,
        total_errors: 0,
        first_seen: nil,
        last_seen: nil
      }
    }
  end

  defp apply_record(state, record) do
    decision_reference = Map.get(record, :decision_ref) || "unknown"
    occurred_at = Map.get(record, :occurred_at, DateTime.utc_now())
    duration_microseconds = Map.get(record, :duration_us, 0)
    matched_rules = matched_rule_identifiers(record)
    is_error = evaluation_error?(record)

    per_decision_entry =
      Map.get(state.per_decision, decision_reference, empty_per_decision_entry())

    updated_per_decision_entry =
      per_decision_entry
      |> increment_count()
      |> add_duration(duration_microseconds)
      |> add_rule_hits(matched_rules)
      |> increment_errors(is_error)
      |> maybe_set_total_rule_count(Map.get(record, :total_rule_count))

    updated_per_decision =
      Map.put(state.per_decision, decision_reference, updated_per_decision_entry)

    updated_global =
      state.global
      |> Map.update!(:total_evaluations, &(&1 + 1))
      |> Map.update!(:total_errors, &(&1 + if(is_error, do: 1, else: 0)))
      |> update_first_seen(occurred_at)
      |> update_last_seen(occurred_at)

    %{state | per_decision: updated_per_decision, global: updated_global}
  end

  defp empty_per_decision_entry do
    %{
      count: 0,
      total_duration_us: 0,
      max_duration_us: 0,
      min_duration_us: nil,
      durations: [],
      rule_hits: %{},
      errors: 0,
      total_rule_count: nil
    }
  end

  defp increment_count(per_decision_entry) do
    %{per_decision_entry | count: per_decision_entry.count + 1}
  end

  defp add_duration(per_decision_entry, duration_microseconds)
       when is_integer(duration_microseconds) and duration_microseconds >= 0 do
    updated_durations =
      [duration_microseconds | per_decision_entry.durations]
      |> Enum.sort()

    %{
      per_decision_entry
      | total_duration_us: per_decision_entry.total_duration_us + duration_microseconds,
        max_duration_us: max(per_decision_entry.max_duration_us, duration_microseconds),
        min_duration_us: min_duration(per_decision_entry.min_duration_us, duration_microseconds),
        durations: updated_durations
    }
  end

  defp add_duration(per_decision_entry, _duration_microseconds), do: per_decision_entry

  defp min_duration(nil, duration_microseconds), do: duration_microseconds

  defp min_duration(current_minimum, duration_microseconds) do
    min(current_minimum, duration_microseconds)
  end

  defp add_rule_hits(per_decision_entry, matched_rule_identifiers) do
    updated_rule_hits =
      Enum.reduce(matched_rule_identifiers, per_decision_entry.rule_hits, fn rule_identifier,
                                                                             rule_hits ->
        Map.update(rule_hits, rule_identifier, 1, &(&1 + 1))
      end)

    %{per_decision_entry | rule_hits: updated_rule_hits}
  end

  defp increment_errors(per_decision_entry, true) do
    %{per_decision_entry | errors: per_decision_entry.errors + 1}
  end

  defp increment_errors(per_decision_entry, false), do: per_decision_entry

  defp maybe_set_total_rule_count(per_decision_entry, nil), do: per_decision_entry

  defp maybe_set_total_rule_count(per_decision_entry, total_rule_count)
       when is_integer(total_rule_count) and total_rule_count > 0 do
    %{per_decision_entry | total_rule_count: total_rule_count}
  end

  defp maybe_set_total_rule_count(per_decision_entry, _invalid), do: per_decision_entry

  defp update_first_seen(global, occurred_at) do
    case global.first_seen do
      nil -> %{global | first_seen: occurred_at}
      _existing -> global
    end
  end

  defp update_last_seen(global, occurred_at) do
    %{global | last_seen: occurred_at}
  end

  defp matched_rule_identifiers(record) do
    case Map.get(record, :matched_rules) do
      rules when is_list(rules) ->
        Enum.map(rules, &normalize_rule_identifier/1)

      _other ->
        matched_rule_count = Map.get(record, :matched_rule_count, 0)

        if matched_rule_count > 0 do
          Enum.map(1..matched_rule_count, fn index -> "rule_#{index}" end)
        else
          []
        end
    end
  end

  defp normalize_rule_identifier(rule_identifier) when is_binary(rule_identifier),
    do: rule_identifier

  defp normalize_rule_identifier(rule_identifier) when is_atom(rule_identifier),
    do: Atom.to_string(rule_identifier)

  defp normalize_rule_identifier(rule_identifier), do: inspect(rule_identifier)

  defp evaluation_error?(record) do
    cond do
      Map.get(record, :error) == true -> true
      Map.get(record, :terminal_state) == :fatal -> true
      true -> false
    end
  end
end

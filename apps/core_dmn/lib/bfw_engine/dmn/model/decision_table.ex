defmodule BfwEngine.DMN.Model.DecisionTable do
  @moduledoc "A DMN decision table with inputs, outputs, rules, and a hit policy."

  alias BfwEngine.DMN.Model.Input
  alias BfwEngine.DMN.Model.Output
  alias BfwEngine.DMN.Model.Rule

  @type hit_policy ::
          :unique | :first | :any | :collect | :rule_order | :output_order | :priority

  @type aggregation :: :sum | :min | :max | :count | nil

  @type orientation :: :rule_as_row | :rule_as_column | :cross_table

  @typedoc """
  Per-column index entry containing value lookups and precomputed wildcards.
  """
  @type column_index_entry :: %{
          values: %{term() => MapSet.t(non_neg_integer())},
          wildcards: MapSet.t(non_neg_integer())
        }

  @typedoc """
  Deploy-time rule index for O(1) candidate filtering on equality inputs.

  Shape: `%{column_index => column_index_entry()}`.
  Built by `Precompiler.build_rule_index/1` for columns where all non-dash
  entries are simple equality literals. `nil` when no columns are indexable.
  """
  @type rule_index :: %{non_neg_integer() => column_index_entry()} | nil

  @type t :: %__MODULE__{
          id: String.t() | nil,
          hit_policy: hit_policy(),
          aggregation: aggregation(),
          preferred_orientation: orientation(),
          inputs: [Input.t()],
          outputs: [Output.t()],
          rules: [Rule.t()],
          rule_index: rule_index()
        }

  defstruct id: nil,
            hit_policy: :unique,
            aggregation: nil,
            preferred_orientation: :rule_as_row,
            inputs: [],
            outputs: [],
            rules: [],
            rule_index: nil
end

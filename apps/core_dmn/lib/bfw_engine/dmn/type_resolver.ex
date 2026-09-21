defmodule BfwEngine.DMN.TypeResolver do
  @moduledoc """
  Resolves DMN `typeRef` values against `ItemDefinition` declarations and
  built-in FEEL types, and coerces runtime input values to the declared shapes.
  """

  alias BfwEngine.DMN.Model.Definitions
  alias BfwEngine.DMN.Model.InputData
  alias BfwEngine.DMN.Model.ItemDefinition
  alias BfwEngine.DMN.Model.Output
  alias BfwEngine.Expressions

  @builtin_type_map %{
    "string" => :string,
    "number" => :number,
    "boolean" => :boolean,
    "date" => :date,
    "time" => :time,
    "dateTime" => :dateTime,
    "dayTimeDuration" => :dayTimeDuration,
    "yearMonthDuration" => :yearMonthDuration,
    "Any" => :Any
  }

  @type builtin_type ::
          :string
          | :number
          | :boolean
          | :date
          | :time
          | :dateTime
          | :dayTimeDuration
          | :yearMonthDuration
          | :Any

  @type type_descriptor :: {:builtin, builtin_type()} | {:item_definition, ItemDefinition.t()}

  @type resolve_result ::
          {:ok, type_descriptor()}
          | {:error, :unknown_type, %{type_ref: String.t()}}

  @type coercion_error ::
          {:error, :type_coercion_failed, %{input: String.t(), expected: String.t(), got: term()}}

  @type warning :: %{
          code: :output_type_mismatch,
          output_id: String.t(),
          output_name: String.t() | nil,
          expected_type_ref: String.t(),
          actual_value: term()
        }

  @doc """
  Resolves a `type_ref` string to a built-in FEEL type or a custom `ItemDefinition`.
  """
  @spec resolve_type(String.t(), Definitions.t()) :: resolve_result()
  def resolve_type(type_ref, %Definitions{} = definitions) when is_binary(type_ref) do
    case Map.get(@builtin_type_map, type_ref) do
      nil -> resolve_item_definition(type_ref, definitions)
      builtin_type -> {:ok, {:builtin, builtin_type}}
    end
  end

  @doc """
  Coerces all `InputData` values in `input_context` according to their declared `type_ref`.
  """
  @spec coerce_input_context(Definitions.t(), map()) ::
          {:ok, map()} | coercion_error() | {:error, :unknown_type, %{type_ref: String.t()}}
  def coerce_input_context(%Definitions{} = definitions, input_context) do
    case coerce_input_context_with_trace(definitions, input_context) do
      {:ok, coerced_context, _traces} -> {:ok, coerced_context}
      error -> error
    end
  end

  @doc """
  Coerces all `InputData` values and returns a coercion trace for each typed input.

  Returns `{:ok, coerced_context, [CoercionTrace.t()]}`.
  Inputs without a `type_ref` or missing from the context produce no trace entry.
  Non-coerced inputs (where the value was already the correct type) are included
  with `coerced: false` for debugger completeness (P7-D3).
  """
  @spec coerce_input_context_with_trace(Definitions.t(), map()) ::
          {:ok, map(), [BfwEngine.DMN.EvaluationTrace.CoercionTrace.t()]}
          | coercion_error()
          | {:error, :unknown_type, %{type_ref: String.t()}}
  def coerce_input_context_with_trace(%Definitions{} = definitions, input_context) do
    case Enum.reduce_while(definitions.input_data, {:ok, input_context, []}, fn
           %InputData{type_ref: nil}, {:ok, context, traces} ->
             {:cont, {:ok, context, traces}}

           %InputData{name: input_name, type_ref: type_ref}, {:ok, context, traces} ->
             coerce_single_input_with_trace(context, traces, input_name, type_ref, definitions)
         end) do
      {:ok, context, reversed_traces} -> {:ok, context, Enum.reverse(reversed_traces)}
      error -> error
    end
  end

  defp coerce_single_input_with_trace(context, traces, input_name, type_ref, definitions) do
    alias BfwEngine.DMN.EvaluationTrace.CoercionTrace

    case fetch_input_value(context, input_name) do
      :missing ->
        {:cont, {:ok, context, traces}}

      {:ok, original_value} ->
        case coerce_value(original_value, type_ref, definitions, input_name) do
          {:ok, coerced_value} ->
            updated_context =
              context
              |> Map.put(input_name, coerced_value)
              |> maybe_delete_atom_key(input_name)

            trace = %CoercionTrace{
              input_name: input_name,
              original_value: original_value,
              coerced_value: coerced_value,
              target_type: type_ref,
              coerced: original_value != coerced_value
            }

            {:cont, {:ok, updated_context, [trace | traces]}}

          {:error, :type_coercion_failed, _} = error ->
            {:halt, error}

          {:error, :unknown_type, _} = error ->
            {:halt, error}
        end
    end
  end

  @doc """
  Coerces a single value to the type identified by `type_ref`.
  """
  @spec coerce_value(term(), String.t(), Definitions.t()) ::
          {:ok, term()} | coercion_error() | {:error, :unknown_type, %{type_ref: String.t()}}
  def coerce_value(value, type_ref, %Definitions{} = definitions) do
    coerce_value(value, type_ref, definitions, type_ref)
  end

  @spec coerce_value(term(), String.t(), Definitions.t(), String.t()) ::
          {:ok, term()} | coercion_error() | {:error, :unknown_type, %{type_ref: String.t()}}
  def coerce_value(value, type_ref, %Definitions{} = definitions, input_label) do
    case resolve_type(type_ref, definitions) do
      {:ok, descriptor} ->
        coerce_to_descriptor(value, descriptor, definitions, input_label, type_ref)

      {:error, _, _} = error ->
        error
    end
  end

  @doc """
  Checks decision table output values against declared output `type_ref` values.

  Returns a list of warning maps (empty when all outputs conform).
  """
  @spec check_output_types(term(), [Output.t()], Definitions.t()) :: [warning()]
  def check_output_types(result, outputs, %Definitions{} = definitions) do
    outputs
    |> Enum.with_index()
    |> Enum.flat_map(fn {output, index} ->
      check_single_output(result, output, index, definitions)
    end)
  end

  @doc """
  Returns `true` when `value` conforms to the type identified by `type_ref`.
  """
  @spec value_conforms?(term(), String.t(), Definitions.t()) :: boolean()
  def value_conforms?(value, type_ref, definitions) do
    case resolve_type(type_ref, definitions) do
      {:ok, descriptor} -> conforms_to_descriptor?(value, descriptor, definitions)
      {:error, _, _} -> false
    end
  end

  defp fetch_input_value(context, input_name) do
    cond do
      Map.has_key?(context, input_name) ->
        {:ok, Map.get(context, input_name)}

      (atom_key = safe_existing_atom(input_name)) && Map.has_key?(context, atom_key) ->
        {:ok, Map.get(context, atom_key)}

      true ->
        :missing
    end
  end

  defp maybe_delete_atom_key(context, input_name) do
    case safe_existing_atom(input_name) do
      nil -> context
      atom_key -> Map.delete(context, atom_key)
    end
  end

  defp resolve_item_definition(type_ref, %Definitions{item_definitions: item_definitions}) do
    case find_item_definition(item_definitions, type_ref) do
      %ItemDefinition{} = item_definition ->
        {:ok, {:item_definition, item_definition}}

      nil ->
        {:error, :unknown_type, %{type_ref: type_ref}}
    end
  end

  defp find_item_definition(item_definitions, type_ref) do
    Enum.find(item_definitions, &(&1.id == type_ref)) ||
      Enum.find(item_definitions, &(&1.name == type_ref))
  end

  defp coerce_to_descriptor(value, {:builtin, builtin_type}, _definitions, input_label, type_ref) do
    case coerce_to_builtin(value, builtin_type) do
      {:ok, coerced} -> {:ok, coerced}
      :error -> coercion_failed(input_label, type_ref, value)
    end
  end

  defp coerce_to_descriptor(value, {:item_definition, item_definition}, definitions, input_label, type_ref) do
    coerce_item_definition(value, item_definition, definitions, input_label, type_ref)
  end

  defp coerce_item_definition(value, %ItemDefinition{} = item_definition, definitions, input_label, type_ref) do
    cond do
      item_definition.is_collection ->
        with {:ok, list_value} <- ensure_list(value),
             {:ok, coerced_elements} <-
               coerce_collection_elements(list_value, item_definition, definitions, input_label, type_ref),
             :ok <- validate_collection_allowed_values(coerced_elements, item_definition.allowed_values) do
          {:ok, coerced_elements}
        else
          :error -> coercion_failed(input_label, type_ref, value)
          {:error, _, _} = error -> error
        end

      item_definition.item_components != [] ->
        coerce_composite_value(value, item_definition, definitions, input_label, type_ref)

      item_definition.type_ref != nil ->
        case coerce_value(value, item_definition.type_ref, definitions, input_label) do
          {:ok, coerced} ->
            finalize_with_allowed_values(coerced, item_definition.allowed_values, input_label, type_ref, value)

          {:error, _, _} = error ->
            error
        end

      true ->
        finalize_with_allowed_values(value, item_definition.allowed_values, input_label, type_ref, value)
    end
  end

  defp coerce_collection_elements(list_value, item_definition, _definitions, _input_label, type_ref) when
         item_definition.type_ref == nil or item_definition.type_ref == type_ref do
    {:ok, list_value}
  end

  defp coerce_collection_elements(list_value, item_definition, definitions, input_label, _type_ref) do
    coerce_each_element(list_value, item_definition.type_ref, definitions, input_label)
  end

  defp coerce_each_element(list_value, element_type_ref, definitions, input_label) do
    list_value
    |> Enum.reduce_while({:ok, []}, fn element, {:ok, accumulated} ->
      case coerce_value(element, element_type_ref, definitions, input_label) do
        {:ok, coerced_element} -> {:cont, {:ok, [coerced_element | accumulated]}}
        {:error, _, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp coerce_composite_value(value, item_definition, definitions, input_label, type_ref) do
    with {:ok, map_value} <- ensure_map(value),
         {:ok, coerced_map} <- coerce_component_fields(map_value, item_definition, definitions, input_label),
         :ok <- validate_allowed_values(coerced_map, item_definition.allowed_values) do
      {:ok, coerced_map}
    else
      :error -> coercion_failed(input_label, type_ref, value)
      {:error, _, _} = error -> error
    end
  end

  defp coerce_component_fields(map_value, item_definition, definitions, input_label) do
    normalized_map = normalize_map_keys(map_value)

    item_definition.item_components
    |> Enum.reduce_while({:ok, %{}}, fn component, {:ok, accumulated} ->
      coerce_component_field(normalized_map, component, definitions, input_label, accumulated)
    end)
  end

  defp coerce_component_field(normalized_map, component, definitions, input_label, accumulated) do
    case Map.fetch(normalized_map, component.name) do
      :error ->
        {:halt, :error}

      {:ok, field_value} ->
        field_type_ref = component.type_ref || "Any"
        coerce_and_accumulate_field(field_value, field_type_ref, component.name, definitions, input_label, accumulated)
    end
  end

  defp coerce_and_accumulate_field(field_value, field_type_ref, component_name, definitions, input_label, accumulated) do
    case coerce_value(field_value, field_type_ref, definitions, input_label) do
      {:ok, coerced_field} ->
        {:cont, {:ok, Map.put(accumulated, component_name, coerced_field)}}

      {:error, _, _} = error ->
        {:halt, error}
    end
  end

  defp finalize_with_allowed_values(value, allowed_values, input_label, type_ref, original_value) do
    case validate_allowed_values(value, allowed_values) do
      :ok -> {:ok, value}
      :error -> coercion_failed(input_label, type_ref, original_value)
    end
  end

  defp coerce_to_builtin(value, :Any), do: {:ok, value}

  defp coerce_to_builtin(value, :string) when is_binary(value), do: {:ok, value}

  defp coerce_to_builtin(value, :string) when is_number(value) or is_boolean(value),
    do: {:ok, to_string(value)}

  defp coerce_to_builtin(value, :number) when is_number(value), do: {:ok, value}

  defp coerce_to_builtin(value, :number) when is_binary(value) do
    case parse_number_string(value) do
      {:ok, number} -> {:ok, number}
      :error -> :error
    end
  end

  defp coerce_to_builtin(value, :boolean) when is_boolean(value), do: {:ok, value}

  defp coerce_to_builtin("true", :boolean), do: {:ok, true}
  defp coerce_to_builtin("false", :boolean), do: {:ok, false}

  defp coerce_to_builtin(value, :date) when is_binary(value) do
    coerce_feel_temporal(value, :date, ~r/^\d{4}-\d{2}-\d{2}$/)
  end

  defp coerce_to_builtin(value, :time) when is_binary(value) do
    coerce_feel_temporal(value, :time, ~r/^\d{2}:\d{2}(:\d{2})?/)
  end

  defp coerce_to_builtin(value, :dateTime) when is_binary(value) do
    coerce_feel_temporal(value, :dateTime, ~r/^\d{4}-\d{2}-\d{2}T/)
  end

  defp coerce_to_builtin(value, :dayTimeDuration) when is_binary(value) do
    coerce_feel_literal(value, :feel_duration_dt)
  end

  defp coerce_to_builtin(value, :yearMonthDuration) when is_binary(value) do
    coerce_feel_literal(value, :feel_duration_ym)
  end

  defp coerce_to_builtin({:feel_date, _} = value, :date), do: {:ok, value}
  defp coerce_to_builtin({:feel_time, _} = value, :time), do: {:ok, value}
  defp coerce_to_builtin({:feel_datetime, _} = value, :dateTime), do: {:ok, value}
  defp coerce_to_builtin({:feel_duration_dt, _} = value, :dayTimeDuration), do: {:ok, value}
  defp coerce_to_builtin({:feel_duration_ym, _} = value, :yearMonthDuration), do: {:ok, value}

  defp coerce_to_builtin(_value, _builtin_type), do: :error

  defp coerce_feel_temporal(string_value, expected_kind, pattern) do
    if Regex.match?(pattern, string_value) do
      coerce_feel_literal(string_value, feel_kind_atom(expected_kind))
    else
      :error
    end
  end

  defp coerce_feel_literal(string_value, expected_tag) do
    case Expressions.eval(~s|@"#{string_value}"|, %{}) do
      {:ok, {^expected_tag, _}} = ok -> ok
      _ -> :error
    end
  end

  defp feel_kind_atom(:date), do: :feel_date
  defp feel_kind_atom(:time), do: :feel_time
  defp feel_kind_atom(:dateTime), do: :feel_datetime

  defp parse_number_string(string_value) do
    case Integer.parse(string_value) do
      {integer, ""} ->
        {:ok, integer}

      _ ->
        case Float.parse(string_value) do
          {float, ""} -> {:ok, float}
          _ -> :error
        end
    end
  end

  defp ensure_list(value) when is_list(value), do: {:ok, value}
  defp ensure_list(value), do: {:ok, [value]}

  defp ensure_map(value) when is_map(value), do: {:ok, normalize_map_keys(value)}
  defp ensure_map(_value), do: :error

  defp normalize_map_keys(map_value) do
    Map.new(map_value, fn {key, value} -> {to_string(key), value} end)
  end

  defp validate_allowed_values(_value, nil), do: :ok

  defp validate_allowed_values(value, allowed_values) do
    case Expressions.evaluate_unary(allowed_values, value) do
      {:ok, true} -> :ok
      _ -> :error
    end
  end

  defp validate_collection_allowed_values(_elements, nil), do: :ok

  defp validate_collection_allowed_values(elements, allowed_values) do
    if Enum.all?(elements, fn element -> validate_allowed_values(element, allowed_values) == :ok end) do
      :ok
    else
      :error
    end
  end

  defp conforms_to_descriptor?(value, {:builtin, builtin_type}, _definitions) do
    conforms_to_builtin?(value, builtin_type)
  end

  defp conforms_to_descriptor?(value, {:item_definition, item_definition}, definitions) do
    cond do
      item_definition.is_collection ->
        is_list(value) &&
          (item_definition.type_ref == nil ||
             Enum.all?(value, fn element ->
               value_conforms?(element, item_definition.type_ref, definitions)
             end))

      item_definition.item_components != [] ->
        composite_conforms?(value, item_definition, definitions)

      item_definition.type_ref != nil ->
        value_conforms?(value, item_definition.type_ref, definitions)

      true ->
        allowed_values_conforms?(value, item_definition.allowed_values)
    end
  end

  defp composite_conforms?(value, item_definition, definitions) when is_map(value) do
    normalized_map = normalize_map_keys(value)

    Enum.all?(item_definition.item_components, fn component ->
      case Map.fetch(normalized_map, component.name) do
        :error ->
          false

        {:ok, field_value} ->
          field_type_ref = component.type_ref || "Any"
          value_conforms?(field_value, field_type_ref, definitions)
      end
    end)
  end

  defp composite_conforms?(_value, _item_definition, _definitions), do: false

  defp conforms_to_builtin?(_value, :Any), do: true
  defp conforms_to_builtin?(value, :string), do: is_binary(value)
  defp conforms_to_builtin?(value, :number), do: is_number(value)
  defp conforms_to_builtin?(value, :boolean), do: is_boolean(value)
  defp conforms_to_builtin?({:feel_date, _}, :date), do: true
  defp conforms_to_builtin?({:feel_time, _}, :time), do: true
  defp conforms_to_builtin?({:feel_datetime, _}, :dateTime), do: true
  defp conforms_to_builtin?({:feel_duration_dt, _}, :dayTimeDuration), do: true
  defp conforms_to_builtin?({:feel_duration_ym, _}, :yearMonthDuration), do: true
  defp conforms_to_builtin?(_value, _builtin_type), do: false

  defp allowed_values_conforms?(_value, nil), do: true

  defp allowed_values_conforms?(value, allowed_values) do
    case Expressions.evaluate_unary(allowed_values, value) do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp check_single_output(_result, %Output{type_ref: nil}, _index, _definitions), do: []

  defp check_single_output(result, %Output{} = output, index, definitions) do
    output_key = "output_#{index}"
    output_value = extract_output_value(result, output_key, output.name)

    if output_value == :missing do
      []
    else
      if value_conforms?(output_value, output.type_ref, definitions) do
        []
      else
        [
          %{
            code: :output_type_mismatch,
            output_id: output.id,
            output_name: output.name,
            expected_type_ref: output.type_ref,
            actual_value: output_value
          }
        ]
      end
    end
  end

  defp extract_output_value(result, output_key, output_name) when is_map(result) do
    cond do
      Map.has_key?(result, output_key) ->
        Map.get(result, output_key)

      output_name != nil && Map.has_key?(result, output_name) ->
        Map.get(result, output_name)

      output_name != nil && has_existing_atom_key?(result, output_name) ->
        Map.get(result, safe_existing_atom(output_name))

      true ->
        :missing
    end
  end

  defp extract_output_value(result, _output_key, _output_name), do: result

  defp has_existing_atom_key?(map, string) do
    case safe_existing_atom(string) do
      nil -> false
      atom_key -> Map.has_key?(map, atom_key)
    end
  end

  defp safe_existing_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end

  defp coercion_failed(input_name, type_ref, value) do
    {:error, :type_coercion_failed, %{input: input_name, expected: type_ref, got: value}}
  end
end

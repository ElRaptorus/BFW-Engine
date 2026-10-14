defmodule BfwEngine.BPMN.Validator.ContractScan do
  @moduledoc """
  Finds `bfw:payloadContract`, `bfw:resultContract`, and `bfw:valueContract` elements whose text is not a
  JSON object.

  The parser keeps any decoded JSON value and turns malformed text into "no contract", so the model cannot
  tell a missing contract from a broken one. This scan reads the raw XML instead. A contract is static JSON
  Schema (never FEEL), so the check does not depend on runtime data. Blank text means "no contract" and passes.
  """

  @behaviour Saxy.Handler

  @contract_elements ["payloadContract", "resultContract", "valueContract"]

  @typedoc "One offending contract: the extension element name and the id of its nearest enclosing element."
  @type offender :: {contract_name :: String.t(), owner_id :: String.t() | nil}

  @doc "Returns the offending contracts in document order. Unparsable XML yields no offenders."
  @spec offenders(String.t()) :: [offender()]
  def offenders(raw_xml) when is_binary(raw_xml) do
    initial_state = %{owner_ids: [], capture: nil, offenders: []}

    case Saxy.parse_string(raw_xml, __MODULE__, initial_state) do
      {:ok, state} -> Enum.reverse(state.offenders)
      {:error, _reason} -> []
    end
  end

  @impl Saxy.Handler
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  def handle_event(:end_document, _data, state), do: {:ok, state}

  def handle_event(:start_element, {raw_name, attributes}, state) do
    name = local_name(raw_name)
    owner_ids = [List.keyfind(attributes, "id", 0) |> id_value() | state.owner_ids]

    if name in @contract_elements do
      owner_id = owner_ids |> tl() |> Enum.find(& &1)
      {:ok, %{state | owner_ids: owner_ids, capture: {name, owner_id, ""}}}
    else
      {:ok, %{state | owner_ids: owner_ids}}
    end
  end

  def handle_event(:characters, chars, %{capture: {name, owner_id, text}} = state) do
    {:ok, %{state | capture: {name, owner_id, text <> chars}}}
  end

  def handle_event(:characters, _chars, state), do: {:ok, state}

  def handle_event(:end_element, raw_name, state) do
    state = %{state | owner_ids: tl(state.owner_ids)}

    case state.capture do
      {name, owner_id, text} ->
        if local_name(raw_name) == name do
          {:ok, finish_capture(state, name, owner_id, text)}
        else
          {:ok, state}
        end

      nil ->
        {:ok, state}
    end
  end

  defp finish_capture(state, name, owner_id, text) do
    state = %{state | capture: nil}

    if json_object_or_blank?(text) do
      state
    else
      %{state | offenders: [{name, owner_id} | state.offenders]}
    end
  end

  defp json_object_or_blank?(text) do
    case String.trim(text) do
      "" ->
        true

      trimmed ->
        match?({:ok, decoded} when is_map(decoded), Jason.decode(trimmed))
    end
  end

  defp id_value({"id", value}), do: value
  defp id_value(nil), do: nil

  defp local_name(raw_name) do
    raw_name |> String.split(":") |> List.last()
  end
end

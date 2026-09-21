defmodule Examples.Plugins.CustomValidators.Scripts.PayloadValidator do
  @moduledoc """
  Ensures string-keyed payload maps include `"name"` and `"amount"`.
  """

  @behaviour BfwEngine.Plugin.NamedScript

  @required_fields ["name", "amount"]

  @doc "Returns a map payload unchanged when string keys name and amount are present, errors with the first missing required field, or rejects non-map payloads."
  @impl true
  def handle_enter(_flow_node, payload, _context) when is_map(payload) do
    case first_missing_field(payload, @required_fields) do
      nil -> {:ok, payload}
      field -> {:error, "missing required field: #{field}"}
    end
  end

  def handle_enter(_flow_node, _payload, _context) do
    {:error, "missing required field: name"}
  end

  defp first_missing_field(payload, fields) do
    Enum.find(fields, fn field ->
      value = Map.get(payload, field)
      value == nil or value == ""
    end)
  end
end

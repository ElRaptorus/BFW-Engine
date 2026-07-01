defmodule Examples.BusinessRules.DecisionServiceSmokeTester.ServiceDiscoverer do
  @moduledoc """
  Lightweight DMN XML scanner that extracts Decision Service element IDs.
  """

  @decision_service_pattern ~r/<(?:\w+:)?decisionService\s[^>]*id="([^"]+)"/

  @doc """
  Returns Decision Service IDs declared in the given DMN XML string.

  Returns an empty list for `nil`, empty strings, or XML without services.
  """
  @spec discover(String.t() | nil) :: [String.t()]
  def discover(nil), do: []

  def discover(dmn_xml) when is_binary(dmn_xml) do
    if dmn_xml == "" do
      []
    else
      @decision_service_pattern
      |> Regex.scan(dmn_xml)
      |> Enum.map(fn [_full_match, service_id] -> service_id end)
    end
  end
end

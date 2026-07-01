defmodule Examples.BusinessRules.DecisionServiceSmokeTester.ServiceDiscovererTest do
  use ExUnit.Case

  alias Examples.BusinessRules.DecisionServiceSmokeTester.ServiceDiscoverer

  @dmn_with_services """
  <?xml version="1.0" encoding="UTF-8"?>
  <definitions>
    <decisionService id="PricingService" name="Pricing Service">
      <outputDecision href="#Decision_final_premium"/>
    </decisionService>
    <decisionService id="SecondaryService" name="Secondary"/>
  </definitions>
  """

  test "discover/1 extracts Decision Service IDs from DMN XML" do
    assert ServiceDiscoverer.discover(@dmn_with_services) == ["PricingService", "SecondaryService"]
  end

  test "discover/1 returns empty list when DMN has no services" do
    dmn_without_services = """
    <?xml version="1.0" encoding="UTF-8"?>
    <definitions>
      <decision id="Decision_only" name="Only Decision"/>
    </definitions>
    """

    assert ServiceDiscoverer.discover(dmn_without_services) == []
  end

  test "discover/1 returns empty list for nil input" do
    assert ServiceDiscoverer.discover(nil) == []
  end

  test "discover/1 returns empty list for empty string" do
    assert ServiceDiscoverer.discover("") == []
  end
end

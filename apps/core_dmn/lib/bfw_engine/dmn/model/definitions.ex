defmodule BfwEngine.DMN.Model.Definitions do
  @moduledoc """
  Root container for a parsed DMN model.

  Corresponds to `<definitions>` in DMN XML and `DmnDefinitions` in
  the TypeScript SDK.
  """

  alias BfwEngine.DMN.Model.BusinessKnowledgeModel
  alias BfwEngine.DMN.Model.Decision
  alias BfwEngine.DMN.Model.DecisionService
  alias BfwEngine.DMN.Model.Import
  alias BfwEngine.DMN.Model.InputData
  alias BfwEngine.DMN.Model.ItemDefinition
  alias BfwEngine.DMN.Model.KnowledgeSource

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          namespace: String.t() | nil,
          decisions: [Decision.t()],
          input_data: [InputData.t()],
          business_knowledge_models: [BusinessKnowledgeModel.t()],
          knowledge_sources: [KnowledgeSource.t()],
          item_definitions: [ItemDefinition.t()],
          imports: [Import.t()],
          decision_services: [DecisionService.t()],
          raw_xml: String.t()
        }

  @enforce_keys [:raw_xml]
  defstruct id: nil,
            name: nil,
            namespace: nil,
            decisions: [],
            input_data: [],
            business_knowledge_models: [],
            knowledge_sources: [],
            item_definitions: [],
            imports: [],
            decision_services: [],
            raw_xml: ""
end

defmodule EvilEngine.BPMN.ExtensionManifest do
  @moduledoc """
  Declarative registry of every `evil:*` BPMN extension element the parser
  (`EvilEngine.BPMN.Parser.SaxHandler`) reads, plus enough metadata for a
  consumer to model, validate, and generate typed accessors for each one
  (Phase 6.1, WP-5 — replaces the cancelled `mix evil.gen.moddle_descriptor`,
  see the plan's D-5).

  This is the Engine's half of the vocabulary contract. The Studio's moddle
  descriptor (`evil-platform.json`, hand-written and Studio-owned per D-5)
  additionally encodes **authoring-time** constraints this manifest
  deliberately omits: `meta.allowedIn`, moddle type hierarchy
  (`superClass`/`extends`/`isAbstract`), and `xml.tagAlias`. Those have no
  counterpart in `sax_handler.ex`, which accepts extensions contextually by
  name with no `allowed_in` concept — inventing them here would move a
  modelling concern into the wrong repository.

  `mix evil.gen.extension_manifest` serializes `build/0` to
  `extension-manifest.json`. A CI diff-guard (see the mix task and
  `apps/core_bpmn/test/evil_engine/bpmn/extension_manifest_test.exs`)
  regenerates and fails the build if committed output drifts from source.

  ## Entry shape

  | Key | Meaning |
  |---|---|
  | `element` | The `evil:*` element name as written in XML (e.g. `httpUrl`) |
  | `value_kind` | `:feel` \\| `:json_schema` \\| `:static_string` \\| `:integer` \\| `:boolean` \\| `:mapping` |
  | `carrier` | `:body` (element body text) \\| `:attributes` (XML attributes) |
  | `attributes` | For `carrier: :attributes`, the attribute names (empty list otherwise) |
  | `applicable_to` | BPMN element types the parser reads this extension on |
  | `model_field` | The Elixir struct field this extension populates, for traceability |

  Plus `extensible/0`: generic containers whose *instance data* the Engine
  does not interpret (`Properties`, `Property` — the bag holding Studio-only
  values like `studio.examplePayload`, see `AGENTS.md` and
  `bpmn-editor/panes/BpmnElementCustomPropertiesFunctions.ts` in the Studio
  repo). Consumer conformance checks should exempt these from the
  "every descriptor type appears in the manifest" direction.
  """

  @type value_kind :: :feel | :json_schema | :static_string | :integer | :boolean | :mapping
  @type carrier :: :body | :attributes

  @type entry :: %{
          element: String.t(),
          value_kind: value_kind(),
          carrier: carrier(),
          attributes: [String.t()],
          applicable_to: [String.t()],
          model_field: String.t()
        }

  # ---------------------------------------------------------------------
  # Process / Definitions level
  # ---------------------------------------------------------------------

  @entries [
    %{
      element: "version",
      value_kind: :static_string,
      carrier: :body,
      attributes: [],
      applicable_to: ["Process"],
      model_field: "Process.version"
    },
    %{
      element: "correlationKey",
      value_kind: :feel,
      carrier: :body,
      attributes: [],
      applicable_to: ["Process"],
      model_field: "Process.correlation_key"
    },
    %{
      element: "LinterRulesetScore",
      value_kind: :static_string,
      carrier: :attributes,
      attributes: [
        "rulesetId",
        "scorePercent",
        "complianceStatus",
        "computedAtIso",
        "schemaVersion",
        "maxPoints",
        "penaltyPoints",
        "rawErrorFindings",
        "rawWarningFindings"
      ],
      applicable_to: ["Definitions"],
      model_field: "Definitions.linter_scores"
    },

    # -------------------------------------------------------------------
    # Shared data-pipeline extensions (ServiceTask, ScriptTask,
    # BusinessRuleTask, UserTask, SendTask, ReceiveTask, CallActivity,
    # SubProcess, AdHocSubProcess — and, for contracts, message events)
    # -------------------------------------------------------------------
    %{
      element: "payloadContract",
      value_kind: :json_schema,
      carrier: :body,
      attributes: [],
      applicable_to: [
        "ServiceTask",
        "ScriptTask",
        "BusinessRuleTask",
        "SendTask",
        "SubProcess",
        "IntermediateThrowEvent",
        "EndEvent"
      ],
      model_field: "*.payload_contract"
    },
    %{
      element: "resultContract",
      value_kind: :json_schema,
      carrier: :body,
      attributes: [],
      applicable_to: [
        "ServiceTask",
        "ScriptTask",
        "BusinessRuleTask",
        "UserTask",
        "ReceiveTask",
        "SubProcess",
        "StartEvent",
        "IntermediateCatchEvent",
        "BoundaryEvent"
      ],
      model_field: "*.result_contract"
    },
    %{
      element: "inputMapping",
      value_kind: :mapping,
      carrier: :attributes,
      attributes: ["source", "target"],
      applicable_to: [
        "ServiceTask",
        "ScriptTask",
        "BusinessRuleTask",
        "UserTask",
        "SendTask",
        "ReceiveTask",
        "CallActivity",
        "SubProcess",
        "IntermediateThrowEvent",
        "EndEvent"
      ],
      model_field: "*.in_mappings"
    },
    %{
      element: "outputMapping",
      value_kind: :mapping,
      carrier: :attributes,
      attributes: ["source", "target"],
      applicable_to: [
        "ServiceTask",
        "ScriptTask",
        "BusinessRuleTask",
        "UserTask",
        "SendTask",
        "ReceiveTask",
        "CallActivity",
        "SubProcess",
        "IntermediateCatchEvent",
        "BoundaryEvent"
      ],
      model_field: "*.out_mappings"
    },
    %{
      element: "dataContract",
      value_kind: :json_schema,
      carrier: :body,
      attributes: [],
      applicable_to: ["FlowNode (any type)"],
      model_field: "FlowNode.data_contracts"
    },
    %{
      element: "valueContract",
      value_kind: :json_schema,
      carrier: :body,
      attributes: [],
      applicable_to: ["DataObject"],
      model_field: "DataObject.value_contract"
    },

    # -------------------------------------------------------------------
    # ServiceTask (HTTP built-in handler, implementation="http")
    # -------------------------------------------------------------------
    %{
      element: "httpUrl",
      value_kind: :static_string,
      carrier: :body,
      attributes: [],
      applicable_to: ["ServiceTask"],
      model_field: "FlowNodeData.ServiceTask.http_url"
    },
    %{
      element: "httpMethod",
      value_kind: :static_string,
      carrier: :body,
      attributes: [],
      applicable_to: ["ServiceTask"],
      model_field: "FlowNodeData.ServiceTask.http_method"
    },
    %{
      element: "httpBody",
      value_kind: :feel,
      carrier: :body,
      attributes: [],
      applicable_to: ["ServiceTask"],
      model_field: "FlowNodeData.ServiceTask.http_body"
    },
    %{
      element: "httpAuthHeader",
      value_kind: :feel,
      carrier: :body,
      attributes: [],
      applicable_to: ["ServiceTask"],
      model_field: "FlowNodeData.ServiceTask.http_auth_header"
    },
    %{
      element: "httpResponseHeaders",
      value_kind: :feel,
      carrier: :body,
      attributes: [],
      applicable_to: ["ServiceTask"],
      model_field: "FlowNodeData.ServiceTask.http_response_headers"
    },

    # -------------------------------------------------------------------
    # ScriptTask
    # -------------------------------------------------------------------
    %{
      element: "scriptRef",
      value_kind: :static_string,
      carrier: :body,
      attributes: [],
      applicable_to: ["ScriptTask"],
      model_field: "FlowNodeData.ScriptTask.script_ref"
    },

    # -------------------------------------------------------------------
    # BusinessRuleTask
    # -------------------------------------------------------------------
    %{
      element: "decisionRef",
      value_kind: :static_string,
      carrier: :body,
      attributes: [],
      applicable_to: ["BusinessRuleTask"],
      model_field: "FlowNodeData.BusinessRuleTask.decision_ref"
    },
    %{
      element: "decisionElementId",
      value_kind: :static_string,
      carrier: :body,
      attributes: [],
      applicable_to: ["BusinessRuleTask"],
      model_field: "FlowNodeData.BusinessRuleTask.decision_element_id"
    },
    %{
      element: "resultVariable",
      value_kind: :static_string,
      carrier: :body,
      attributes: [],
      applicable_to: ["BusinessRuleTask"],
      model_field: "FlowNodeData.BusinessRuleTask.result_variable"
    },
    %{
      element: "traceUnmatchedRules",
      value_kind: :boolean,
      carrier: :body,
      attributes: [],
      applicable_to: ["BusinessRuleTask"],
      model_field: "FlowNodeData.BusinessRuleTask.trace_unmatched_rules"
    },
    %{
      element: "ruleRef",
      value_kind: :static_string,
      carrier: :body,
      attributes: [],
      applicable_to: ["BusinessRuleTask"],
      model_field: "FlowNodeData.BusinessRuleTask.rule_ref"
    },

    # -------------------------------------------------------------------
    # UserTask
    # -------------------------------------------------------------------
    %{
      element: "assignees",
      value_kind: :feel,
      carrier: :body,
      attributes: [],
      applicable_to: ["UserTask"],
      model_field: "FlowNodeData.UserTask.assignees_expression"
    },
    %{
      element: "formFields",
      value_kind: :json_schema,
      carrier: :body,
      attributes: [],
      applicable_to: ["UserTask"],
      model_field: "FlowNodeData.UserTask.form_schema"
    },
    %{
      element: "formActions",
      value_kind: :json_schema,
      carrier: :body,
      attributes: [],
      applicable_to: ["UserTask"],
      model_field: "FlowNodeData.UserTask.form_actions"
    },
    %{
      element: "dueDate",
      value_kind: :feel,
      carrier: :body,
      attributes: [],
      applicable_to: ["UserTask"],
      model_field: "FlowNodeData.UserTask.due_date"
    },
    %{
      element: "priority",
      value_kind: :integer,
      carrier: :body,
      attributes: [],
      applicable_to: ["UserTask"],
      model_field: "FlowNodeData.UserTask.priority"
    },

    # -------------------------------------------------------------------
    # ManualTask
    # -------------------------------------------------------------------
    %{
      element: "requireConfirmation",
      value_kind: :boolean,
      carrier: :body,
      attributes: [],
      applicable_to: ["ManualTask"],
      model_field: "FlowNodeData.ManualTask.require_confirmation"
    },

    # -------------------------------------------------------------------
    # Message event extensions
    # -------------------------------------------------------------------
    %{
      element: "correlationRetrievalExpression",
      value_kind: :feel,
      carrier: :body,
      attributes: [],
      applicable_to: ["IntermediateThrowEvent", "EndEvent", "SendTask"],
      model_field: "EventDefinition.Message.correlation_retrieval_expression"
    },
    %{
      element: "payload",
      value_kind: :feel,
      carrier: :body,
      attributes: [],
      applicable_to: ["IntermediateThrowEvent", "EndEvent"],
      model_field: "EventDefinition.Message.payload_expression"
    },
    %{
      element: "eventMapping",
      value_kind: :feel,
      carrier: :body,
      attributes: [],
      applicable_to: ["StartEvent", "IntermediateCatchEvent", "BoundaryEvent"],
      model_field: "EventDefinition.Message.event_mapping"
    },

    # -------------------------------------------------------------------
    # Error event extensions
    # -------------------------------------------------------------------
    %{
      element: "errorCode",
      value_kind: :static_string,
      carrier: :body,
      attributes: [],
      applicable_to: ["EndEvent", "BoundaryEvent"],
      model_field: "EventDefinition.Error.error_code"
    },
    %{
      element: "errorMessage",
      value_kind: :static_string,
      carrier: :body,
      attributes: [],
      applicable_to: ["EndEvent", "BoundaryEvent"],
      model_field: "EventDefinition.Error.error_message"
    },

    # -------------------------------------------------------------------
    # CallActivity
    # -------------------------------------------------------------------
    %{
      element: "startEventId",
      value_kind: :static_string,
      carrier: :body,
      attributes: [],
      applicable_to: ["CallActivity"],
      model_field: "FlowNodeData.CallActivity.start_event_id"
    },

    # -------------------------------------------------------------------
    # Ad-hoc SubProcess
    # -------------------------------------------------------------------
    %{
      element: "activeElements",
      value_kind: :feel,
      carrier: :body,
      attributes: [],
      applicable_to: ["SubProcess (adHocSubProcess)"],
      model_field: "FlowNodeData.SubProcess.active_elements_expression"
    },

    # -------------------------------------------------------------------
    # Multi-Instance / Standard Loop
    # -------------------------------------------------------------------
    %{
      element: "inputCollection",
      value_kind: :feel,
      carrier: :body,
      attributes: [],
      applicable_to: ["MultiInstanceLoopCharacteristics"],
      model_field: "MultiInstance.collection_expression"
    },
    %{
      element: "outputCollection",
      value_kind: :feel,
      carrier: :body,
      attributes: [],
      applicable_to: ["MultiInstanceLoopCharacteristics"],
      model_field: "MultiInstance.output_collection"
    },
    %{
      element: "elementVariable",
      value_kind: :static_string,
      carrier: :body,
      attributes: [],
      applicable_to: ["MultiInstanceLoopCharacteristics"],
      model_field: "MultiInstance.element_variable"
    },
    %{
      element: "outputElementVariable",
      value_kind: :static_string,
      carrier: :body,
      attributes: [],
      applicable_to: ["MultiInstanceLoopCharacteristics"],
      model_field: "MultiInstance.output_element_variable"
    },
    %{
      element: "loopBreakCondition",
      value_kind: :feel,
      carrier: :body,
      attributes: [],
      applicable_to: ["MultiInstanceLoopCharacteristics"],
      model_field: "MultiInstance.loop_break_condition"
    },
    %{
      element: "loopInterval",
      value_kind: :static_string,
      carrier: :body,
      attributes: [],
      applicable_to: ["MultiInstanceLoopCharacteristics", "StandardLoopCharacteristics"],
      model_field: "MultiInstance.loop_interval / StandardLoop.loop_interval"
    },
    %{
      element: "maxIterations",
      value_kind: :integer,
      carrier: :body,
      attributes: [],
      applicable_to: ["MultiInstanceLoopCharacteristics"],
      model_field: "MultiInstance.max_iterations"
    }
  ]

  @extensible ["Properties", "Property"]

  @doc "Every `evil:*` extension element the parser reads, as a list of entries (see moduledoc)."
  @spec build() :: [entry()]
  def build, do: @entries

  @doc """
  Generic containers whose instance data the Engine does not interpret.
  Consumer conformance checks exempt these from the
  "every descriptor type appears in the manifest" direction (D-5, §4.6).
  """
  @spec extensible() :: [String.t()]
  def extensible, do: @extensible

  @doc "The full manifest as a plain map, ready for JSON encoding."
  @spec to_map() :: %{elements: [entry()], extensible: [String.t()]}
  def to_map do
    %{elements: build(), extensible: extensible()}
  end

  @doc """
  Pretty-printed JSON for committed `extension-manifest.json` files.

  Encodes through `Jason.OrderedObject` so object key order is stable
  across Mix environments — `Jason.encode!(map)` follows BEAM map
  iteration order and is not byte-stable.
  """
  @spec to_json() :: String.t()
  def to_json do
    Jason.OrderedObject.new([
      {"extensible", extensible()},
      {"elements", Enum.map(build(), &entry_to_ordered_object/1)}
    ])
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp entry_to_ordered_object(entry) do
    Jason.OrderedObject.new([
      {"element", entry.element},
      {"value_kind", Atom.to_string(entry.value_kind)},
      {"carrier", Atom.to_string(entry.carrier)},
      {"attributes", entry.attributes},
      {"applicable_to", entry.applicable_to},
      {"model_field", entry.model_field}
    ])
  end
end

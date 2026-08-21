defmodule EvilEngineWeb.Graphql.ModelSchema.CommonFields do
  @moduledoc """
  Shared Absinthe field-group macros for the BPMN Model graph (WP-2).

  Defined in their own module (rather than inline in `ModelTypes`) and
  `import`-ed there, because Absinthe's `object`/`interface` macros expand
  their `do...end` block in a context that does not see macros defined
  earlier in the *same* module — only macros brought in via `import`.
  """

  defmacro common_flow_node_fields do
    quote do
      field(:id, non_null(:id))
      field(:name, :string)
      field(:type, non_null(:flow_node_type))
      field(:incoming, non_null(list_of(non_null(:string))))
      field(:outgoing, non_null(list_of(non_null(:string))))
      field(:boundary_event_refs, non_null(list_of(non_null(:string))))
      field(:data_contracts, non_null(list_of(non_null(:data_contract))))
      field(:data_input_associations, non_null(list_of(non_null(:data_association))))
      field(:data_output_associations, non_null(list_of(non_null(:data_association))))
      field(:multi_instance, :multi_instance)
      field(:standard_loop, :standard_loop)
      field(:is_for_compensation, non_null(:boolean))
      field(:documentation, :string)

      @desc "The flow node ID of the enclosing SubProcess/Transaction/AdHocSubProcess shell, or null at the top level. Only meaningful (and only populated) on `ProcessModel.allFlowNodes` entries — always null on the nested `flowNodes` tree, where the parent is implicit."
      field(:parent_sub_process_id, :string)
    end
  end

  defmacro mapping_fields do
    quote do
      field(:in_mappings, non_null(list_of(non_null(:mapping))))
      field(:out_mappings, non_null(list_of(non_null(:mapping))))
    end
  end
end

defmodule EvilEngine.Persistence.Resources.FlowNodeInstance do
  @moduledoc """
  Ash resource for the `flow_node_instances` table (§4.2).

  Tracks each individual BPMN flow node execution within a process
  instance. Token payloads (`input_token`, `output_token`) and
  `type_properties` carry LZ4 JSONB compression.
  """

  use Ash.Resource,
    domain: EvilEngine.Persistence.Api,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false

  alias EvilEngine.Persistence.RepoRouter

  graphql do
    type :flow_node_instance

    queries do
      get(:get_flow_node_instance, :read)
      list(:flow_node_instances, :read, paginate_with: :offset)
    end
  end

  policies do
    bypass action_type([:create, :update]) do
      authorize_if always()
    end

    bypass action_type(:read) do
      authorize_if {EvilEngine.Persistence.Checks.ZeekyBoogieDoog, []}
    end

    policy action_type(:read) do
      authorize_if expr(
                     exists(
                       :process_instance,
                       started_by["id"] == ^actor(:id) or
                         exists(
                           :flow_node_instances,
                           is_nil(lane_name) or lane_name in ^actor(:accessible_lanes)
                         )
                     )
                   )
    end
  end

  postgres do
    table "flow_node_instances"
    repo &RepoRouter.repo/2

    custom_indexes do
      index [:process_instance_id],
        name: "flow_node_instances_process_instance_id_idx"

      index [:process_instance_id, :lane_name],
        name: "flow_node_instances_process_instance_id_lane_idx"

      index [:state],
        where: "state = 'active'",
        name: "flow_node_instances_state_active_idx"

      index [:flow_node_type, :state],
        name: "flow_node_instances_type_state_idx"

      index [:multi_instance_id],
        where: "multi_instance_id IS NOT NULL",
        name: "flow_node_instances_multi_instance_id_idx"
    end

    check_constraints do
      check_constraint :deleted,
                       "flow_node_instances_deleted_consistency",
                       check: """
                       (deleted = false AND deleted_at IS NULL AND deleted_by IS NULL)
                       OR (deleted = true AND deleted_at IS NOT NULL AND deleted_by IS NOT NULL)
                       """,
                       message:
                         "deleted_at and deleted_by must both be set when deleted is true, and both NULL when false"
    end
  end

  actions do
    defaults []

    read :read do
      primary? true
      filter expr(deleted == false)

      pagination do
        required? false
        offset? true
        countable :by_default
      end
    end

    create :create do
      primary? true

      accept [
        :id,
        :process_instance_id,
        :flow_node_id,
        :flow_node_type,
        :event_type,
        :lane_name,
        :state,
        :started_at,
        :previous_flow_node_instance_ids,
        :triggerer_flow_node_instance_id,
        :input_token,
        :type_properties,
        :multi_instance_id,
        :iteration_index
      ]
    end

    update :update_state do
      accept [:state]
    end

    update :update_waiting do
      accept [:state, :type_properties]
    end

    update :update_finished do
      accept [
        :state,
        :finished_at,
        :output_token,
        :type_properties,
        :error_info,
        :previous_flow_node_instance_ids,
        :triggerer_flow_node_instance_id
      ]
    end

    update :retry_reset do
      accept [:state, :finished_at, :output_token, :error_info, :type_properties]
    end

    destroy :retry_delete do
      primary? false
    end

    update :soft_delete do
      accept [:deleted, :deleted_at, :deleted_by]
    end
  end

  attributes do
    attribute :id, :uuid_v7 do
      writable? true
      public? true
      primary_key? true
      allow_nil? false
      default &Ash.UUIDv7.generate/0
    end

    attribute :process_instance_id, :uuid, allow_nil?: false, public?: true
    attribute :flow_node_id, :string, allow_nil?: false, public?: true
    attribute :flow_node_type, :string, allow_nil?: false, public?: true
    attribute :event_type, :string, public?: true
    attribute :lane_name, :string, public?: true

    attribute :state, :string do
      allow_nil? false
      public? true
    end

    attribute :started_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :finished_at, :utc_datetime_usec, public?: true

    attribute :previous_flow_node_instance_ids, {:array, :uuid} do
      default []
      public? true
    end

    attribute :triggerer_flow_node_instance_id, :uuid, public?: true

    attribute :input_token, :map, public?: true
    attribute :output_token, :map, public?: true
    attribute :type_properties, :map, public?: true
    attribute :error_info, :map, public?: true

    attribute :multi_instance_id, :uuid, public?: true
    attribute :iteration_index, :integer, public?: true

    attribute :deleted, :boolean do
      allow_nil? false
      default false
      public? false
    end

    attribute :deleted_at, :utc_datetime_usec, public?: false
    attribute :deleted_by, :map, public?: false
  end

  relationships do
    belongs_to :process_instance, EvilEngine.Persistence.Resources.ProcessInstance do
      attribute_writable? true
      define_attribute? false
    end
  end
end

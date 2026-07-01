defmodule EvilEngine.Persistence.Resources.ProcessInstance do
  @moduledoc """
  Ash resource for the `process_instances` table (§4.2).

  Tracks the lifecycle of a single BPMN process execution. Each row
  is immutably pinned to the `process_version_id` it was started on.
  A version cannot be soft-deleted while non-terminal PIs exist on it
  (enforced by the DELETE endpoint guards). If a version is deleted
  despite this guard (e.g. manual DB manipulation), resume fails with
  a not-found error.

  Payload cap notes:
    - No `final_token` column — derived via Ash calculation in Phase 1.
    - `started_with_context` carries LZ4 JSONB compression.
  """

  use Ash.Resource,
    domain: EvilEngine.Persistence.Api,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false

  alias EvilEngine.Persistence.RepoRouter

  graphql do
    type :process_instance

    queries do
      get(:get_process_instance, :read)
      list(:process_instances, :read, paginate_with: :offset)
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
      authorize_if expr(started_by["id"] == ^actor(:id))

      authorize_if expr(
                     exists(
                       :flow_node_instances,
                       is_nil(lane_name) or lane_name in ^actor(:accessible_lanes)
                     )
                   )
    end
  end

  postgres do
    table "process_instances"
    repo &RepoRouter.repo/2

    custom_indexes do
      index [:state],
        where: "state = 'running'",
        name: "process_instances_state_running_idx"

      index [:process_version_id, :state],
        name: "process_instances_version_state_idx"

      index [:business_key],
        name: "process_instances_business_key_idx"

      index [:parent_process_instance_id],
        where: "parent_process_instance_id IS NOT NULL",
        name: "process_instances_parent_pi_id_idx"
    end

    check_constraints do
      check_constraint :deleted,
                       "process_instances_deleted_consistency",
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
        :process_version_id,
        :parent_process_instance_id,
        :business_key,
        :triggerer_flow_node_instance_id,
        :state,
        :started_at,
        :started_by,
        :started_with_context
      ]
    end

    update :update_state do
      accept [:state, :finished_at, :error_info]
    end

    update :retry_reset do
      accept [:state, :finished_at, :process_version_id, :error_info]
    end

    update :revert_retry do
      accept [:state, :finished_at]
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

    attribute :process_version_id, :uuid, allow_nil?: false, public?: true
    attribute :parent_process_instance_id, :uuid, public?: true
    attribute :business_key, :string, public?: true
    attribute :triggerer_flow_node_instance_id, :uuid, public?: true

    attribute :state, :string do
      allow_nil? false
      public? true
    end

    attribute :started_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :finished_at, :utc_datetime_usec, public?: true

    attribute :started_by, :map, public?: true
    attribute :started_with_context, :map, public?: true
    attribute :error_info, :map, public?: true

    attribute :deleted, :boolean do
      allow_nil? false
      default false
      public? false
    end

    attribute :deleted_at, :utc_datetime_usec, public?: false
    attribute :deleted_by, :map, public?: false
  end

  relationships do
    belongs_to :process_version, EvilEngine.Persistence.Resources.ProcessVersion do
      attribute_writable? true
      define_attribute? false
      public? true
    end

    has_many :flow_node_instances, EvilEngine.Persistence.Resources.FlowNodeInstance do
      destination_attribute :process_instance_id
      public? true
    end

    has_many :data_object_values, EvilEngine.Persistence.Resources.DataObject do
      destination_attribute :process_instance_id
      public? true
    end

    has_many :data_object_history, EvilEngine.Persistence.Resources.DataObjectWrite do
      destination_attribute :process_instance_id
      public? true
    end
  end

  calculations do
    calculate :final_tokens, {:array, :map}, EvilEngine.Persistence.Calculations.FinalTokens do
      public? true
      description "End-event output tokens for finished PIs; nil for all other states"
    end

    calculate :id_text, :string, expr(fragment("?::text", id)) do
      public? true
      filterable? true
      description "UUID primary key cast to text — enables substring (ilike) search in GraphQL"
    end
  end
end

defmodule EvilEngine.Persistence.Resources.DataObject do
  @moduledoc """
  Ash resource for the `data_objects` table.

  Snapshot of the latest value for each Data Object within a process
  instance. Updated via UPSERT on every DOA write. The full history
  lives in `DataObjectWrite`.

  Both the snapshot and history tables share the same column set
  (`id`, `process_instance_id`, `data_object_id`, `flow_node_instance_id`,
  `value`, `created_at`) so the SDK can expose a single unified
  `DataObjectValue` type.

  Policies:
  - ZeekyBoogieDoog bypass for admin tools
  - Internal engine writes bypass (no actor needed for create/update)
  - Reads scoped to PIs the actor started or has lane access to
  - No actor_absent bypass (fail closed)
  """

  use Ash.Resource,
    domain: EvilEngine.Persistence.Api,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias EvilEngine.Persistence.RepoRouter

  graphql do
    type :data_object_value

    queries do
      get(:get_data_object_value, :read)
      list(:data_object_values, :read, paginate_with: :offset)
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
    table "data_objects"
    repo &RepoRouter.repo/2
  end

  actions do
    defaults []

    read :read do
      primary? true

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
        :data_object_id,
        :flow_node_instance_id,
        :value,
        :created_at
      ]
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
    attribute :data_object_id, :string, allow_nil?: false, public?: true
    attribute :flow_node_instance_id, :uuid, allow_nil?: false, public?: true
    attribute :value, EvilEngine.Persistence.Types.JsonbAny, public?: true
    attribute :created_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :process_instance, EvilEngine.Persistence.Resources.ProcessInstance do
      attribute_writable? true
      define_attribute? false
    end
  end
end

defmodule EvilEngine.Persistence.Resources.DataObjectWrite do
  @moduledoc """
  Ash resource for the `data_object_writes` table.

  Append-only audit trail of every value written to a Data Object.
  The underlying table may be partitioned by `created_at` depending
  on `EVIL_PARTITION_INTERVAL`.

  Writes are performed via raw Ecto in `ExecutionAdapter` (not through
  Ash actions) because the partitioned table requires direct SQL INSERT.
  The Ash resource exposes only `:read` for GraphQL and facade queries.

  Shares the same column set as the snapshot table (`data_objects`)
  so the SDK can expose a single unified `DataObjectValue` type.

  Policies: ZeekyBoogieDoog bypass, reads scoped to PIs the actor
  started or has lane access to, no actor_absent bypass.
  """

  use Ash.Resource,
    domain: EvilEngine.Persistence.Api,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias EvilEngine.Persistence.RepoRouter

  graphql do
    type :data_object_history_entry

    queries do
      list(:data_object_history, :read, paginate_with: :offset)
    end
  end

  policies do
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
    table "data_object_writes"
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
    attribute :value, EvilEngine.Persistence.Types.JsonbAny, allow_nil?: false, public?: true
    attribute :created_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :process_instance, EvilEngine.Persistence.Resources.ProcessInstance do
      attribute_writable? true
      define_attribute? false
    end
  end
end

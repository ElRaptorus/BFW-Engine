defmodule BfwEngine.Persistence.Resources.GatewayPendingArrival do
  @moduledoc """
  Ash resource for the `gateway_pending_arrivals` table.

  Buffers token arrivals at parallel/inclusive gateway joins. One row
  per (gateway FNI, incoming branch). Rows are deleted atomically when
  the gateway fires or the enclosing scope is interrupted.

  Not partitioned — the working set is bounded by the number of
  currently-waiting gateway joins across all running PIs.
  """

  use Ash.Resource,
    domain: BfwEngine.Persistence.Api,
    data_layer: AshPostgres.DataLayer

  alias BfwEngine.Persistence.RepoRouter

  postgres do
    table "gateway_pending_arrivals"
    repo &RepoRouter.repo/2

    custom_indexes do
      index [:process_instance_id],
        name: "gateway_pending_arrivals_process_instance_id_idx"

      index [:gateway_flow_node_instance_id],
        name: "gateway_pending_arrivals_gateway_flow_node_instance_idx"
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :process_instance_id,
        :gateway_flow_node_instance_id,
        :source_branch_sequence_flow_id,
        :source_flow_node_instance_id,
        :arrived_payload,
        :arrived_at
      ]
    end

    destroy :destroy do
      primary? true
    end
  end

  identities do
    identity :unique_branch_arrival, [
      :gateway_flow_node_instance_id,
      :source_branch_sequence_flow_id
    ]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :process_instance_id, :uuid, allow_nil?: false, public?: true
    attribute :gateway_flow_node_instance_id, :uuid, allow_nil?: false, public?: true
    attribute :source_branch_sequence_flow_id, :string, allow_nil?: false, public?: true
    attribute :source_flow_node_instance_id, :uuid, allow_nil?: false, public?: true
    attribute :arrived_payload, :map, allow_nil?: false, public?: true
    attribute :arrived_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end
end

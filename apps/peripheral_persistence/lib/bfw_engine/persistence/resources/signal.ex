defmodule BfwEngine.Persistence.Resources.Signal do
  @moduledoc """
  Ash resource for the `signals` audit table.

  Append-only record of every published signal. Signals carry no
  payload and no correlation value — only the signal name and origin.
  """

  use Ash.Resource,
    domain: BfwEngine.Persistence.Api,
    data_layer: AshPostgres.DataLayer

  alias BfwEngine.Persistence.RepoRouter
  alias BfwEngine.Persistence.Types.JsonbList

  postgres do
    table "signals"
    repo &RepoRouter.repo/2
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :id,
        :signal_name,
        :origin,
        :published_at,
        :deliveries,
        :started_process_instance_ids
      ]
    end

    update :append_delivery do
      accept [:deliveries]
    end

    update :update_started_process_instance_ids do
      accept [:started_process_instance_ids]
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

    attribute :signal_name, :string, allow_nil?: false, public?: true
    attribute :origin, :map, allow_nil?: true, public?: true

    attribute :published_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0

    attribute :deliveries, JsonbList,
      allow_nil?: false,
      public?: true,
      default: []

    attribute :started_process_instance_ids, JsonbList,
      allow_nil?: false,
      public?: true,
      default: []
  end
end

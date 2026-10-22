defmodule BfwEngine.Persistence.Resources.Message do
  @moduledoc """
  Ash resource for the `messages` audit table.

  Append-only record of every published message. For partitioned
  deployments, `published_at` is part of the composite PK.
  """

  use Ash.Resource,
    domain: BfwEngine.Persistence.Api,
    data_layer: AshPostgres.DataLayer

  alias BfwEngine.Persistence.RepoRouter
  alias BfwEngine.Persistence.Types.JsonbList

  postgres do
    table "messages"
    repo &RepoRouter.repo/2
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :id,
        :message_name,
        :payload,
        :correlation_value,
        :origin,
        :published_at,
        :correlations
      ]
    end

    update :append_correlation do
      accept [:correlations]
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

    attribute :message_name, :string, allow_nil?: false, public?: true
    attribute :payload, :map, allow_nil?: true, public?: true
    attribute :correlation_value, :string, allow_nil?: true, public?: true
    attribute :origin, :map, allow_nil?: true, public?: true

    attribute :published_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0

    attribute :correlations, JsonbList,
      allow_nil?: false,
      public?: true,
      default: []

    attribute :started_process_instance_ids, {:array, :string},
      allow_nil?: false,
      public?: true,
      default: []
  end
end

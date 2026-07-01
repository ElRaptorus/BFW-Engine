defmodule EvilEngine.Persistence.Resources.Process do
  @moduledoc """
  Ash resource for the `processes` table.

  Represents a deployed BPMN process definition. Each process is
  identified by a unique `process_model_id` (the BPMN process ID) and
  can have multiple versions deployed over time.
  """

  use Ash.Resource,
    domain: EvilEngine.Persistence.Api,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias EvilEngine.Persistence.RepoRouter

  policies do
    bypass do
      authorize_if {EvilEngine.Persistence.Checks.ZeekyBoogieDoog, []}
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end

    policy action_type(:create) do
      authorize_if expr(^actor(:deploy_bpmn) == true)
    end

    policy action_type(:update) do
      authorize_if expr(^actor(:deploy_bpmn) == true)
    end
  end

  graphql do
    type :process

    queries do
      get(:get_process, :read)
      list(:processes, :read, paginate_with: :offset)
    end
  end

  postgres do
    table "processes"
    repo &RepoRouter.repo/2
  end

  actions do
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
      accept [:id, :process_model_id, :name, :enabled, :created_at]
    end

    update :update_enabled do
      accept [:enabled]
    end
  end

  identities do
    identity :unique_process_model_id, [:process_model_id]
  end

  attributes do
    attribute :id, :uuid_v7 do
      writable? true
      public? true
      primary_key? true
      allow_nil? false
      default &Ash.UUIDv7.generate/0
    end

    attribute :process_model_id, :string do
      allow_nil? false
      public? true
    end

    attribute :name, :string, public?: true

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :created_at, :utc_datetime_usec do
      allow_nil? false
      default &DateTime.utc_now/0
      public? true
    end
  end

  relationships do
    has_many :versions, EvilEngine.Persistence.Resources.ProcessVersion do
      destination_attribute :process_id
      public? true
    end
  end
end

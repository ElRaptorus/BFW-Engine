defmodule EvilEngine.Persistence.Resources.DecisionDefinition do
  @moduledoc """
  Ash resource for the `decision_definitions` table.

  Represents a deployed DMN decision definition. Each definition is
  identified by a unique `decision_definition_id` (the DMN decision ID)
  and can have multiple versions deployed over time.
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
      authorize_if expr(^actor(:deploy_dmn) == true)
    end

    policy action_type(:update) do
      authorize_if expr(^actor(:deploy_dmn) == true)
    end
  end

  graphql do
    type :decision_definition

    queries do
      get(:get_decision_definition, :read)
      list(:decision_definitions, :read, paginate_with: :offset)
    end
  end

  postgres do
    table "decision_definitions"
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
      accept [:id, :decision_definition_id, :name, :enabled, :created_at]
    end

    update :update_enabled do
      accept [:enabled]
    end
  end

  identities do
    identity :unique_decision_definition_id, [:decision_definition_id]
  end

  attributes do
    attribute :id, :uuid_v7 do
      writable? true
      public? true
      primary_key? true
      allow_nil? false
      default &Ash.UUIDv7.generate/0
    end

    attribute :decision_definition_id, :string do
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
    has_many :versions, EvilEngine.Persistence.Resources.DecisionVersion do
      destination_attribute :decision_definition_id
      public? true
    end
  end
end

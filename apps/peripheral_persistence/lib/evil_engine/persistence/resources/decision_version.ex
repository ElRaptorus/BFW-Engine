defmodule EvilEngine.Persistence.Resources.DecisionVersion do
  @moduledoc """
  Ash resource for the `decision_versions` table.

  Each row represents a deployed version of a DMN decision. The
  `dmn_xml` stores the raw DMN XML for audit/re-deployment.
  Soft-delete marks versions as unavailable for new evaluations
  without losing the audit trail.
  """

  use Ash.Resource,
    domain: EvilEngine.Persistence.Api,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false

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
      authorize_if expr(^actor(:delete_dmn) == true)
    end
  end

  graphql do
    type :decision_version

    queries do
      get(:get_decision_version, :read)
      list(:decision_versions, :read, paginate_with: :offset)
    end
  end

  postgres do
    table "decision_versions"
    repo &RepoRouter.repo/2

    check_constraints do
      check_constraint :deleted,
                       "decision_versions_deleted_consistency",
                       check: """
                       (deleted = false AND deleted_at IS NULL AND deleted_by IS NULL)
                       OR (deleted = true AND deleted_at IS NOT NULL AND deleted_by IS NOT NULL)
                       """,
                       message: "deleted_at and deleted_by must be set when deleted is true"
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
      accept [:id, :decision_definition_id, :version, :dmn_xml, :deployer, :deployed_at]
    end

    update :soft_delete do
      accept [:deleted, :deleted_at, :deleted_by]
    end
  end

  identities do
    identity :unique_decision_version, [:decision_definition_id, :version]
  end

  attributes do
    attribute :id, :uuid_v7 do
      writable? true
      public? true
      primary_key? true
      allow_nil? false
      default &Ash.UUIDv7.generate/0
    end

    attribute :decision_definition_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :version, :string do
      allow_nil? false
      public? true
    end

    attribute :dmn_xml, :string do
      allow_nil? false
      public? true
    end

    attribute :deployer, :map, public?: true

    attribute :deleted, :boolean do
      allow_nil? false
      default false
      public? false
    end

    attribute :deleted_at, :utc_datetime_usec, public?: false
    attribute :deleted_by, :map, public?: false

    attribute :deployed_at, :utc_datetime_usec do
      allow_nil? false
      default &DateTime.utc_now/0
      public? true
    end
  end

  relationships do
    belongs_to :decision_definition, EvilEngine.Persistence.Resources.DecisionDefinition do
      attribute_writable? true
      define_attribute? false
    end
  end
end

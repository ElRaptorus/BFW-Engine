defmodule EvilEngine.Persistence.Resources.ProcessVersion do
  @moduledoc """
  Ash resource for the `process_versions` table.

  Each row represents a deployed version of a BPMN process. The
  `bpmn_xml` stores the raw BPMN XML for audit/re-deployment.
  Soft-delete marks versions as unavailable for new starts
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
      authorize_if expr(^actor(:deploy_bpmn) == true)
    end

    policy action_type(:update) do
      authorize_if expr(^actor(:delete_bpmn) == true)
    end
  end

  graphql do
    type :process_version

    queries do
      get(:get_process_version, :read)
      list(:process_versions, :read, paginate_with: :offset)
    end
  end

  postgres do
    table "process_versions"
    repo &RepoRouter.repo/2

    check_constraints do
      check_constraint :deleted,
                       "process_versions_deleted_consistency",
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
      accept [:id, :process_id, :version, :definitions_id, :bpmn_xml, :deployer, :deployed_at]
    end

    update :soft_delete do
      accept [:deleted, :deleted_at, :deleted_by]
    end
  end

  identities do
    identity :unique_process_version, [:process_id, :version]
  end

  attributes do
    attribute :id, :uuid_v7 do
      writable? true
      public? true
      primary_key? true
      allow_nil? false
      default &Ash.UUIDv7.generate/0
    end

    attribute :process_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :version, :string do
      allow_nil? false
      public? true
    end

    attribute :definitions_id, :string, public?: true

    attribute :bpmn_xml, :string, public?: true
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
    belongs_to :process, EvilEngine.Persistence.Resources.Process do
      attribute_writable? true
      define_attribute? false
    end

    has_many :process_instances, EvilEngine.Persistence.Resources.ProcessInstance do
      destination_attribute :process_version_id
      public? true
    end
  end
end

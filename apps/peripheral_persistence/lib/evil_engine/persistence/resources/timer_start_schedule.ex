defmodule EvilEngine.Persistence.Resources.TimerStartSchedule do
  @moduledoc """
  Ash resource for the `timer_start_schedules` table.

  Operational (not audit) rows for cycle Timer Start Event schedules.
  PI-scoped catch/boundary timers are stored on FNI `type_properties`
  and never appear here. Rows are deleted on version unregister or
  cascade when a `process_versions` row is hard-deleted.
  """

  use Ash.Resource,
    domain: EvilEngine.Persistence.Api,
    data_layer: AshPostgres.DataLayer

  alias EvilEngine.Persistence.RepoRouter

  postgres do
    table "timer_start_schedules"
    repo &RepoRouter.repo/2

    custom_indexes do
      index [:enabled, :next_fire_at],
        name: "timer_start_schedules_armed_idx"
    end

    check_constraints do
      check_constraint :kind,
                       "timer_start_schedules_kind_cycle",
                       check: "kind = 'cycle'",
                       message: "kind must be cycle"
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :id,
        :process_version_id,
        :process_model_id,
        :flow_node_id,
        :kind,
        :iso_spec,
        :enabled,
        :next_fire_at,
        :last_triggered_at,
        :cycle_total,
        :cycle_remaining,
        :scheduler_ref
      ]
    end

    update :update do
      primary? true
      accept [
        :enabled,
        :next_fire_at,
        :last_triggered_at,
        :cycle_total,
        :cycle_remaining,
        :scheduler_ref
      ]
    end

    destroy :destroy do
      primary? true
    end
  end

  identities do
    identity :unique_version_flow_node, [:process_version_id, :flow_node_id]
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
    attribute :process_model_id, :string, allow_nil?: false, public?: true
    attribute :flow_node_id, :string, allow_nil?: false, public?: true
    attribute :kind, :string, allow_nil?: false, public?: true
    attribute :iso_spec, :string, allow_nil?: false, public?: true
    attribute :enabled, :boolean, allow_nil?: false, public?: true, default: true
    attribute :next_fire_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :last_triggered_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :cycle_total, :integer, allow_nil?: true, public?: true
    attribute :cycle_remaining, :integer, allow_nil?: true, public?: true
    attribute :scheduler_ref, :string, allow_nil?: true, public?: true

    create_timestamp :inserted_at, type: :utc_datetime_usec, public?: true
    update_timestamp :updated_at, type: :utc_datetime_usec, public?: true
  end
end

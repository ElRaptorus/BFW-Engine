defmodule BfwEngine.Persistence.Resources.PendingSignal do
  @moduledoc """
  Ash resource for the `pending_signals` table.

  Buffered signals that had no matching subscription or start event at
  publish time. Rows transition `pending` -> `delivered` | `expired` | `cancelled`.
  Signals carry no payload and no correlation value.
  """

  use Ash.Resource,
    domain: BfwEngine.Persistence.Api,
    data_layer: AshPostgres.DataLayer

  alias BfwEngine.Persistence.RepoRouter

  postgres do
    table "pending_signals"
    repo &RepoRouter.repo/2
  end

  actions do
    read :read do
      primary? true
    end

    create :create do
      primary? true

      accept [
        :id,
        :signal_id,
        :signal_name,
        :published_at,
        :expires_at,
        :state
      ]
    end

    update :mark_delivered do
      accept []

      validate compare(:state, is_equal: "pending")

      change filter(expr(state == "pending"))
      change set_attribute(:state, "delivered")
      change set_attribute(:delivered_at, &DateTime.utc_now/0)
    end

    update :mark_expired do
      accept []

      change set_attribute(:state, "expired")
      change set_attribute(:expired_at, &DateTime.utc_now/0)
    end

    update :mark_cancelled do
      accept []
      change set_attribute(:state, "cancelled")
    end

    destroy :destroy_if_pending do
      validate compare(:state, is_equal: "pending")
      change filter(expr(state == "pending"))
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

    attribute :signal_id, :uuid, allow_nil?: false, public?: true
    attribute :signal_name, :string, allow_nil?: false, public?: true

    attribute :published_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0

    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :state, :string, allow_nil?: false, public?: true, default: "pending"
    attribute :delivered_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :expired_at, :utc_datetime_usec, allow_nil?: true, public?: true
  end
end

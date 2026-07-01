defmodule EvilEngine.Persistence.Resources.PendingMessage do
  @moduledoc """
  Ash resource for the `pending_messages` table.

  Buffered messages that had no matching subscription at publish time.
  Rows transition from `pending` → `delivered` | `expired` | `cancelled`.
  """

  use Ash.Resource,
    domain: EvilEngine.Persistence.Api,
    data_layer: AshPostgres.DataLayer

  alias EvilEngine.Persistence.RepoRouter

  postgres do
    table "pending_messages"
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
        :message_id,
        :message_name,
        :correlation_value,
        :payload,
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
  end

  attributes do
    attribute :id, :uuid_v7 do
      writable? true
      public? true
      primary_key? true
      allow_nil? false
      default &Ash.UUIDv7.generate/0
    end

    attribute :message_id, :uuid, allow_nil?: false, public?: true
    attribute :message_name, :string, allow_nil?: false, public?: true
    attribute :correlation_value, :string, allow_nil?: true, public?: true
    attribute :payload, :map, allow_nil?: true, public?: true

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

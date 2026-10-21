defmodule BfwEngine.Api.TriggerOriginTest do
  @moduledoc """
  A message or signal published through the facade records who published it:
  plugins are named, other callers are recorded by identity.
  """
  use ExUnit.Case, async: false

  alias BfwEngine.Api
  alias BfwEngine.Events.MessageSubscriptions
  alias BfwEngine.Events.SignalSubscriptions
  alias BfwEngine.Types.Identity

  defmodule CapturingAdapter do
    @moduledoc false

    def insert_message(attributes), do: capture(attributes)
    def insert_signal(attributes), do: capture(attributes)
    def insert_pending_message(_attributes), do: {:ok, "pending"}
    def insert_pending_signal(_attributes), do: {:ok, "pending"}
    def cancel_pending_for_message(_name, _correlation), do: {:ok, 0}
    def cancel_pending_for_signal_name(_name), do: {:ok, 0}
    def append_message_correlation(_id, _correlation), do: :ok
    def append_signal_delivery(_id, _delivery), do: :ok
    def update_started_process_instance_ids(_id, _ids), do: :ok

    defp capture(attributes) do
      send(Application.fetch_env!(:api_facade, :origin_test_pid), {:audited, attributes.origin})
      {:ok, "audit"}
    end
  end

  setup do
    previous_message = Application.get_env(:core_events, :message_persistence_adapter)
    previous_signal = Application.get_env(:core_events, :signal_persistence_adapter)
    Application.put_env(:core_events, :message_persistence_adapter, CapturingAdapter)
    Application.put_env(:core_events, :signal_persistence_adapter, CapturingAdapter)
    Application.put_env(:api_facade, :origin_test_pid, self())

    MessageSubscriptions.mark_ready()
    SignalSubscriptions.mark_ready()

    on_exit(fn ->
      Application.put_env(:core_events, :message_persistence_adapter, previous_message)
      Application.put_env(:core_events, :signal_persistence_adapter, previous_signal)
      Application.delete_env(:api_facade, :origin_test_pid)
    end)
  end

  test "a plugin message is attributed to the plugin by name" do
    identity = %Identity{id: "plugin:billing", roles: [], groups: []}

    {:ok, _result} = Api.publish_message("order", %{}, nil, identity, skip_claims: true)

    assert_receive {:audited, %{source: "plugin", plugin_name: "billing"}}
  end

  test "a plugin signal is attributed to the plugin by name" do
    identity = %Identity{id: "plugin:billing", roles: [], groups: []}

    {:ok, _result} = Api.publish_signal("go", identity, skip_claims: true)

    assert_receive {:audited, %{source: "plugin", plugin_name: "billing"}}
  end

  test "an API caller is attributed by identity" do
    identity = %Identity{id: "user-7", roles: [], groups: []}

    {:ok, _result} = Api.publish_message("order", %{}, nil, identity, skip_claims: true)

    assert_receive {:audited, %{source: "api", triggered_by: "user-7"}}
  end
end

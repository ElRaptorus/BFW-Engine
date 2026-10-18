defmodule BfwEngine.Events.SubscriptionsReadinessTest do
  use ExUnit.Case, async: false

  alias BfwEngine.Events.MessageSubscriptions
  alias BfwEngine.Events.SignalSubscriptions

  setup do
    on_exit(fn ->
      MessageSubscriptions.mark_ready()
      SignalSubscriptions.mark_ready()
    end)
  end

  for subscriptions <- [MessageSubscriptions, SignalSubscriptions] do
    test "#{inspect(subscriptions)}.mark_not_ready/0 clears readiness until mark_ready/0" do
      subscriptions = unquote(subscriptions)
      :ok = subscriptions.mark_ready()

      assert :ok = subscriptions.mark_not_ready()
      refute subscriptions.ready?()
      assert {:error, :timeout} = subscriptions.await_ready(20)

      :ok = subscriptions.mark_ready()
      assert subscriptions.ready?()
      assert :ok = subscriptions.await_ready(20)
    end

    test "#{inspect(subscriptions)}.await_ready/1 leaves no late reply in the caller's mailbox" do
      subscriptions = unquote(subscriptions)
      :ok = subscriptions.mark_not_ready()

      assert {:error, :timeout} = subscriptions.await_ready(20)
      :ok = subscriptions.mark_ready()

      refute_receive _late_reply, 100
    end
  end
end

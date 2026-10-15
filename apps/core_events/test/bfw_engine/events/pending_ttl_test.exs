defmodule BfwEngine.Events.PendingTtlTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias BfwEngine.Events.PendingTtl

  setup do
    original = Application.fetch_env(:core_events, :message_pending_ttl)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:core_events, :message_pending_ttl, value)
        :error -> Application.delete_env(:core_events, :message_pending_ttl)
      end
    end)
  end

  test "converts seconds, minutes, and hours" do
    for {value, expected_seconds} <- [{"PT0S", 0}, {"PT45S", 45}, {"PT5M", 300}, {"PT2H", 7200}] do
      Application.put_env(:core_events, :message_pending_ttl, value)
      assert PendingTtl.seconds(:message_pending_ttl) == expected_seconds
    end
  end

  test "defaults to 60 seconds when the key is not configured" do
    Application.delete_env(:core_events, :message_pending_ttl)
    assert PendingTtl.seconds(:message_pending_ttl) == 60
  end

  test "falls back to 60 seconds with a warning for unsupported values instead of raising" do
    for value <- ["PT1M30S", "PTXS", "P1D", "60", "", nil, 60] do
      Application.put_env(:core_events, :message_pending_ttl, value)

      log =
        capture_log(fn ->
          assert PendingTtl.seconds(:message_pending_ttl) == 60
        end)

      assert log =~ "unsupported value"
    end
  end
end

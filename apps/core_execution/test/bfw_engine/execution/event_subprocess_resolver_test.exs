defmodule BfwEngine.Execution.EventSubprocessResolverTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Execution.EventSubprocessResolver
  alias BfwEngine.Execution.EventSubprocessTrigger

  defp error_trigger(node_id, error_code, opts \\ []) do
    %EventSubprocessTrigger{
      subprocess_node_id: node_id,
      start_event_id: node_id <> "_Start",
      trigger_kind: :error,
      is_interrupting: Keyword.get(opts, :is_interrupting, true),
      error_code: error_code,
      armed?: Keyword.get(opts, :armed?, true)
    }
  end

  defp escalation_trigger(node_id, escalation_code, opts \\ []) do
    %EventSubprocessTrigger{
      subprocess_node_id: node_id,
      start_event_id: node_id <> "_Start",
      trigger_kind: :escalation,
      is_interrupting: Keyword.get(opts, :is_interrupting, true),
      escalation_code: escalation_code,
      armed?: Keyword.get(opts, :armed?, true)
    }
  end

  defp as_map(triggers), do: Map.new(triggers, &{&1.subprocess_node_id, &1})

  describe "find_matching_error_start/2" do
    test "specific error code beats catch-all" do
      triggers = as_map([error_trigger("ESP_CatchAll", nil), error_trigger("ESP_Specific", "E1")])

      assert {:ok, %EventSubprocessTrigger{subprocess_node_id: "ESP_Specific"}} =
               EventSubprocessResolver.find_matching_error_start(triggers, %{error_code: "E1"})
    end

    test "catch-all matches when no specific code matches" do
      triggers = as_map([error_trigger("ESP_CatchAll", nil), error_trigger("ESP_Specific", "E1")])

      assert {:ok, %EventSubprocessTrigger{subprocess_node_id: "ESP_CatchAll"}} =
               EventSubprocessResolver.find_matching_error_start(triggers, %{error_code: "E2"})
    end

    test "accepts string-keyed error_code" do
      triggers = as_map([error_trigger("ESP_Specific", "E1")])

      assert {:ok, %EventSubprocessTrigger{subprocess_node_id: "ESP_Specific"}} =
               EventSubprocessResolver.find_matching_error_start(triggers, %{"error_code" => "E1"})
    end

    test "returns :none when nothing matches and no catch-all exists" do
      triggers = as_map([error_trigger("ESP_Specific", "E1")])

      assert :none =
               EventSubprocessResolver.find_matching_error_start(triggers, %{error_code: "E99"})
    end

    test "ignores disarmed triggers" do
      triggers = as_map([error_trigger("ESP_Specific", "E1", armed?: false)])

      assert :none =
               EventSubprocessResolver.find_matching_error_start(triggers, %{error_code: "E1"})
    end

    test "ignores escalation and other-kind triggers" do
      triggers = as_map([escalation_trigger("ESP_Esc", "E1")])

      assert :none =
               EventSubprocessResolver.find_matching_error_start(triggers, %{error_code: "E1"})
    end
  end

  describe "find_matching_escalation_start/2" do
    test "specific escalation code beats catch-all" do
      triggers =
        as_map([
          escalation_trigger("ESP_CatchAll", nil),
          escalation_trigger("ESP_Specific", "ES1")
        ])

      assert {:ok, %EventSubprocessTrigger{subprocess_node_id: "ESP_Specific"}} =
               EventSubprocessResolver.find_matching_escalation_start(triggers, %{
                 escalation_code: "ES1"
               })
    end

    test "catch-all matches when no specific code matches" do
      triggers =
        as_map([
          escalation_trigger("ESP_CatchAll", nil),
          escalation_trigger("ESP_Specific", "ES1")
        ])

      assert {:ok, %EventSubprocessTrigger{subprocess_node_id: "ESP_CatchAll"}} =
               EventSubprocessResolver.find_matching_escalation_start(triggers, %{
                 escalation_code: "ES2"
               })
    end

    test "accepts string-keyed escalation_code" do
      triggers = as_map([escalation_trigger("ESP_Specific", "ES1")])

      assert {:ok, %EventSubprocessTrigger{subprocess_node_id: "ESP_Specific"}} =
               EventSubprocessResolver.find_matching_escalation_start(triggers, %{
                 "escalation_code" => "ES1"
               })
    end

    test "returns :none when nothing matches and no catch-all exists" do
      triggers = as_map([escalation_trigger("ESP_Specific", "ES1")])

      assert :none =
               EventSubprocessResolver.find_matching_escalation_start(triggers, %{
                 escalation_code: "ES99"
               })
    end

    test "ignores non-escalation triggers" do
      triggers = as_map([error_trigger("ESP_Err", "ES1")])

      assert :none =
               EventSubprocessResolver.find_matching_escalation_start(triggers, %{
                 escalation_code: "ES1"
               })
    end
  end
end

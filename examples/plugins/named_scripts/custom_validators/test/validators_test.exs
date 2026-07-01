defmodule Examples.Plugins.CustomValidators.ValidatorsTest do
  use ExUnit.Case

  alias Examples.Plugins.CustomValidators.Scripts.{
    CurrencyConverter,
    IdempotencyGuard,
    PayloadValidator
  }

  describe "PayloadValidator" do
    test "rejects payloads missing name" do
      assert {:error, message} =
               PayloadValidator.handle_enter(%{}, %{"amount" => 10}, %{})

      assert message =~ "name"
    end

    test "accepts a complete payload" do
      payload = %{"name" => "demo", "amount" => 42}

      assert {:ok, ^payload} =
               PayloadValidator.handle_enter(%{}, payload, %{})
    end
  end

  describe "CurrencyConverter" do
    test "converts USD into EUR using the bundled rate" do
      payload = %{"amount" => 100, "currency" => "USD"}

      assert {:ok, result} =
               CurrencyConverter.handle_enter(%{}, payload, %{})

      assert result["original_currency"] == "USD"
      assert result["converted_currency"] == "EUR"
      assert_in_delta result["converted_amount"], 92.0, 0.0001
    end
  end

  describe "IdempotencyGuard" do
    test "blocks when processed_flag is true in data objects" do
      payload = %{"order_id" => "1"}
      context = %{data_objects: %{"processed_flag" => true}}

      assert {:error, "already processed"} =
               IdempotencyGuard.handle_enter(%{}, payload, context)
    end

    test "allows first-time processing" do
      payload = %{"order_id" => "1"}
      context = %{data_objects: %{}}

      assert {:ok, %{"processing_started" => true} = result} =
               IdempotencyGuard.handle_enter(%{}, payload, context)

      assert Map.fetch!(result, "order_id") == "1"
    end
  end
end

defmodule BfwEngineWeb.Graphql.ErrorsTest do
  use ExUnit.Case, async: true

  alias BfwEngineWeb.Graphql.Errors

  describe "to_graphql_error/1 with :payload_too_large" do
    test "translates payload_too_large with full details" do
      result =
        Errors.to_graphql_error(
          {:error, :payload_too_large, %{size: 100_000, limit: 65_536, field: :payload}}
        )

      assert result.message == "Payload exceeds the maximum allowed size"
      assert result.extensions.code == "PAYLOAD_TOO_LARGE"
      assert result.extensions.size == 100_000
      assert result.extensions.limit == 65_536
      assert result.extensions.field == "payload"
    end

    test "converts atom field names to strings" do
      result =
        Errors.to_graphql_error(
          {:error, :payload_too_large, %{size: 1, limit: 2, field: :result}}
        )

      assert result.extensions.field == "result"
    end
  end

  describe "to_graphql_error/1 with bare {:error, reason}" do
    test "translates a bare atom reason" do
      result = Errors.to_graphql_error({:error, :unauthorized})

      assert result.message == "Operation failed: unauthorized"
      assert result.extensions.code == "UNAUTHORIZED"
    end

    test "uppercases multi-word reasons" do
      result = Errors.to_graphql_error({:error, :not_found})

      assert result.extensions.code == "NOT_FOUND"
    end
  end

  describe "to_graphql_error/1 with {:error, reason, details}" do
    test "translates a generic error with detail map" do
      result =
        Errors.to_graphql_error({:error, :validation_failed, %{fields: [:name, :email]}})

      assert result.message == "Operation failed: validation_failed"
      assert result.extensions.code == "VALIDATION_FAILED"
      assert result.extensions.fields == [:name, :email]
    end
  end
end

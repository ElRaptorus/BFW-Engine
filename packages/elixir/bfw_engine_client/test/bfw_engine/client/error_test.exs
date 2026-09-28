defmodule BfwEngine.Client.ErrorTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Client.Error

  describe "from_response/2" do
    test "maps a known domain error code to its fixed reason" do
      error = Error.from_response(404, %{"error" => "process_not_found", "message" => "gone"})

      assert error.status == 404
      assert error.code == "process_not_found"
      assert error.reason == :process_not_found
      assert error.message == "gone"
    end

    test "falls back to the HTTP status code when the wire code is unknown" do
      error = Error.from_response(404, %{"error" => "totally_unknown_code"})

      assert error.reason == :not_found
      assert error.code == "totally_unknown_code"
      assert error.message == "totally_unknown_code"
    end

    test "falls back to :engine_error when both the code and the status are unknown" do
      error = Error.from_response(599, %{"error" => "totally_unknown_code"})

      assert error.reason == :engine_error
    end

    test "defaults the message to the status code when the body is not a map" do
      error = Error.from_response(500, "internal error")

      assert error.status == 500
      assert error.code == "unknown"
      assert error.reason == :internal_engine_error
      assert error.message == "The Engine responded with status 500"
      assert error.body == "internal error"
    end

    for {status, reason} <- [
          {400, :bad_request},
          {401, :unauthorized},
          {403, :forbidden},
          {404, :not_found},
          {409, :conflict},
          {422, :validation_error},
          {500, :internal_engine_error},
          {503, :engine_at_capacity}
        ] do
      test "status #{status} without a wire code falls back to #{inspect(reason)}" do
        error = Error.from_response(unquote(status), %{})
        assert error.reason == unquote(reason)
      end
    end
  end

  describe "from_graphql_error/1" do
    test "maps extensions.code to its fixed reason" do
      graphql_error = %{
        "message" => "not found",
        "extensions" => %{"code" => "process_not_found"}
      }

      error = Error.from_graphql_error(graphql_error)

      assert error.status == nil
      assert error.code == "process_not_found"
      assert error.reason == :process_not_found
      assert error.message == "not found"
      assert error.body == graphql_error
    end

    test "falls back to :engine_error when extensions.code is absent" do
      error = Error.from_graphql_error(%{"message" => "boom"})

      assert error.code == "unknown"
      assert error.reason == :engine_error
    end

    test "normalises an uppercase GraphQL code before the table lookup" do
      error =
        Error.from_graphql_error(%{"extensions" => %{"code" => "PROCESS_NOT_FOUND"}})

      assert error.code == "PROCESS_NOT_FOUND"
      assert error.reason == :process_not_found
    end

    test "normalises spaces in a GraphQL code before the table lookup" do
      error =
        Error.from_graphql_error(%{"extensions" => %{"code" => "PAYLOAD TOO LARGE"}})

      assert error.code == "PAYLOAD TOO LARGE"
      assert error.reason == :payload_too_large
    end

    test "uses the code as message when message is absent" do
      error = Error.from_graphql_error(%{"extensions" => %{"code" => "process_not_found"}})

      assert error.reason == :process_not_found
      assert error.message == "process_not_found"
    end
  end

  test "message/1 returns the human-readable message" do
    error = Error.from_response(404, %{"error" => "process_not_found", "message" => "gone"})
    assert Exception.message(error) == "gone"
  end
end
